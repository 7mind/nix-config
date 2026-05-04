# Bug report draft — ollama upstream

Title suggestion:

> ollama-engine + SYCL backend silently SIGSEGVs (NULL deref in `ggml_backend_sched_graph_compute_async`) on hybrid-architecture models — qwen3.5moe, qwen3next, nemotron_h

---

## What happens

When ollama 0.23.0 is built with the GGML SYCL backend (Intel Arc family), and a model whose architecture is on the `OllamaEngineRequired()` list (`qwen35moe`, `qwen3next`, `nemotron_h`, `nemotron_h_moe`, `qwen3vl*`, etc.) is loaded, the runner subprocess crashes with a silent SIGSEGV at `addr=0x0` inside `ggml_backend_sched_graph_compute_async` on the **first** prompt request. The model loads successfully and the runner reports `llama runner started in N seconds`; the crash happens at graph compute, not at load.

There is **no preceding `Error OP` / `Exception caught` / `unresolved external symbol` line** from ggml-sycl, only the bare Go SIGSEGV stack trace, which suggests a NULL function pointer or NULL data pointer is being dereferenced inside the scheduler — most likely a backend interface entry that the new Go-native engine expects ggml-sycl to provide for these models' op set, but which is unimplemented.

Architectures that use the legacy llama.cpp runner (qwen2, qwen3, llama, gemma, glm-4.7, mistral, …) all work correctly via the same SYCL backend.

## Reproduction

Hardware: Intel Arc Pro B70 (Battlemage / Xe2, dGPU, 32 GiB).
Stack:
- ollama 0.23.0 (built from source with `-DGGML_SYCL=ON -DGGML_SYCL_TARGET=INTEL`)
- ggml-sycl from upstream `llama.cpp@15bff84bf56651d6f991f166a2bf0f362996f7f9` (eleiton's verified-safe pin) surgically spliced over ollama's vendored ggml-sycl directory; everything else (ggml-base, ggml-cuda, ggml-vulkan, ggml-cpu) at ollama's pinned `ec98e20021f7611db3bbcf6bb6629fed6e1ce4f0`
- intel-llvm @ unstable-2025-11-14 (provides DPC++/SYCL — `libsycl.so.8`)
- intel-compute-runtime 26.09.37435.1 + level-zero, OpenCL backend (OpenCL chosen because intel-compute-runtime's GMM helper aborts during Level Zero init on B70)
- oneMKL 2025.3.1 (libsycl.so.8 ABI-compatible)

Symptoms reproduced with all of:
- `ollama run qwen3.5:4b "say hi"`
- `ollama run qwen3.5:4b-bf16 "say hi"`
- `ollama run qwen3.6:latest "say hi"` (qwen3next arch)
- `ollama run nemotron-3-nano:4b "say hi"` (nemotron-3 hybrid arch)

`ollama list` confirms the models are pulled. The same models load + serve correctly via `llama-cli` from upstream llama.cpp built against the same ggml-sycl source — confirming ggml-sycl itself functions for these tensors and that the bug surface is on the ollama-engine ↔ SYCL boundary, not in ggml-sycl proper.

## Symptom log

Server log around the crash (`journalctl -u ollama`):

```
time=2026-05-04T12:05:08.618+01:00 level=INFO source=ggml.go:490 msg="offloading 40 repeating layers to GPU"
time=2026-05-04T12:05:08.618+01:00 level=INFO source=ggml.go:497 msg="offloading output layer to GPU"
time=2026-05-04T12:05:08.618+01:00 level=INFO source=device.go:240 msg="model weights" device=SYCL0 size="22.0 GiB"
time=2026-05-04T12:05:08.618+01:00 level=INFO source=device.go:251 msg="kv cache" device=SYCL0 size="2.2 GiB"
time=2026-05-04T12:05:08.618+01:00 level=INFO source=device.go:262 msg="compute graph" device=SYCL0 size="4.5 GiB"
time=2026-05-04T12:05:16.143+01:00 level=INFO source=server.go:1432 msg="llama runner started in 9.37 seconds"
[GIN] POST /api/generate                       200    10.024s
SIGSEGV: segmentation violation
PC=0x763a79a08bab m=23 sigcode=128 addr=0x0
signal arrived during cgo execution

goroutine 1311 gp=0x251fb3215a40 m=23 mp=0x251fb33d0808 [syscall]:
runtime.cgocall(0x15ca900, 0x251fb3606a88)
        runtime/cgocall.go:167 +0x4b fp=0x251fb3606a60 sp=0x251fb3606a28 pc=0x4a01ab
github.com/ollama/ollama/ml/backend/ggml._Cfunc_ggml_backend_sched_graph_compute_async(...)
        _cgo_gotypes.go:977 +0x46
github.com/ollama/ollama/ml/backend/ggml.(*Context).ComputeWithNotify(...)
        github.com/ollama/ollama/ml/backend/ggml/ggml.go:833 +0x1b0
github.com/ollama/ollama/runner/ollamarunner.(*Server).computeBatch(...)
        github.com/ollama/ollama/runner/ollamarunner/runner.go:723 +0x892
...
[GIN] POST /api/chat                           500    483.885ms
level=ERROR source=server.go:316 msg="llama runner terminated" error="exit status 2"
```

Notably absent: any `Error OP <NAME>`, `Exception caught at ggml-sycl.cpp:NNNN`, `unresolved external symbol`, or `GGML_ABORT(...)` line that ggml-sycl normally prints for kernel-side or op-dispatch failures. The crash is purely host-side.

## What I think is going on

Hybrid-arch models (Transformer + Mamba2 SSM, MoE+Mamba, etc.) are routed exclusively through the new Go-native ollama-engine via `OllamaEngineRequired()` (`fs/ggml/ggml.go:277`). The legacy llama.cpp runner is bypassed because `llama.LoadModelFromFile` would fail on the unrecognised architecture (verified: `llama_model_load: error loading model architecture: unknown model architecture: 'qwen35moe'`).

The Go-native engine constructs the compute graph in Go and uses `ggml_backend_sched_*` to dispatch ops. For these architectures the graph contains Mamba ops (SSM_SCAN, SSM_CONV, GATED_DELTA_NET) and some MoE-specific ops (mul_mat_id with bf16, fused MoE mul_mat_vec_q). ggml-sycl in the spliced `llama.cpp@15bff84` (and even master) doesn't have full SYCL implementations for the Mamba SSM kernels; the upstream history shows these were largely added for CUDA / WebGPU / Vulkan but not SYCL (e.g., `dd2914dc81 ggml-webgpu: support for SSM_SCAN`, `098705a29e CUDA: fuse SSM_CONV+ADD+SILU`, no equivalent SYCL commits). When the scheduler dispatches an unsupported op, the backend's function pointer for that op-class is NULL and the C side faults inside `ggml_backend_sched_graph_compute_async`.

The mismatch is thus on the boundary between the new engine (which assumes ggml backends advertise / handle the full op set required by the hybrid models it ships) and ggml-sycl (which currently doesn't). The ggml backend interface ought to either reject these ops at scheduler-eval time (so the scheduler can fall back per-op to CPU), or the new engine needs to verify the backend's `supports_op` coverage before assuming dispatch will succeed, OR the SYCL backend needs Mamba SSM kernels.

## Suggested ways forward (any one of these would fix it)

1. **Have `ggml_backend_sched_*` reject unsupported-op dispatches with a printed `Error OP` instead of the underlying NULL-deref**, so failures are diagnosable rather than silent SIGSEGVs. This is the lowest-effort win and benefits every backend, not just SYCL.
2. **Add Mamba SSM kernels (SSM_SCAN, SSM_CONV) to ggml-sycl** — match the recent CUDA/WebGPU additions. This unblocks all hybrid architectures on Intel GPUs.
3. **Have the new engine probe `supports_op` for required ops at model load** and fall back (or error loudly) when the chosen backend can't service them, similar to how the legacy path uses `ggml_backend_sched`'s per-op fallback to CPU.
4. **Bump ollama's vendored llama.cpp** to a SHA that knows `qwen35moe`/`nemotron_h`/etc. on the legacy path — that lets users opt out of the new engine via the existing fallback in `llm/server.go:148-160`. Tracked separately at #15601.

## Existing related signals on the tracker

- **#11160** "Enable Intel GPU support with SYCL backend" — long-standing community PR, currently mergeable=false / dirty.
- **#15601** "Vulkan/AMD performance: vendored llama.cpp (b7437, Dec 2025) missing …" — explicit vendor-staleness complaint covering the same root staleness this report touches.
- **#15890** "Vulkan backend crashes with C++ exception on Intel ARC A750 when using gemma4 26b MoE" — same class of failure on a different backend, suggests "MoE/hybrid + Intel" is the broader gap.
- **#15827** "Intel Battlemage … oneAPI runner missing" — companion infrastructure gap.

## Environment dump

```
ollama --version: 0.23.0 (custom build)
GPU: Intel Arc Pro B70 (8086:e223, Battlemage)
xe driver: kernel 6.19.14 (NixOS 26.05)
intel-compute-runtime: 26.09.37435.1
level-zero: matching
SYCL backend: -DGGML_SYCL=ON -DGGML_SYCL_TARGET=INTEL -DGGML_SYCL_F16=ON -DGGML_SYCL_GRAPH=OFF
SYCL device selector: opencl:gpu (Level Zero crashes on B70 due to GMM init bug in intel-compute-runtime 26.09)
ggml-sycl source: spliced from llama.cpp@15bff84bf5 (Jan 8 2026)
rest of ggml: ollama's vendored ec98e2002 (Dec 16 2025)
```

Happy to provide the full Nix derivation, llama-cli reproduction script, or longer logs if useful.

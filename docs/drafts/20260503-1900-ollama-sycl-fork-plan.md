# ollama-sycl: forking ollama 0.21 to add a SYCL backend for Arc Pro B70

Status: planning, no code written yet.
Goal: 30B+ models on the B70 (Battlemage Xe2) via Level Zero, bypassing Mesa Vulkan's per-buffer cap that breaks ollama-vulkan on this card.

## Why a fork (not a flag)

ollama 0.21's vendored `ml/backend/ggml/ggml/src/` deliberately omits the `ggml-sycl/` directory — the CMake hook `ggml_add_backend(SYCL)` is present (line 438) but there's nothing to compile. The Go-side discoverer in `discover/runner.go:105` routes by `.so` directory name (`vulkan`, `cuda`, `rocm`) and has no SYCL/Level-Zero branch. So enabling SYCL needs source integration, not a build flag.

## Phase-1 findings (2026-05-03)

### Upstream commit ollama 0.21 vendors

`ec98e20021f7611db3bbcf6bb6629fed6e1ce4f0` from `github.com/ggml-org/llama.cpp` (2025-12-16). Pinned via `Makefile.sync` at the ollama repo root. Vendoring is `rsync -arvzc --delete` from upstream `ggml/` into `ml/backend/ggml/ggml/`, with local-only patches under `llama/patches/*.patch`.

Implication: copy `ggml/src/ggml-sycl/` from this exact SHA. Different SHA risks ABI drift against the other backends already vendored (ggml-cuda, ggml-vulkan, ggml-cpu, etc).

### ipex-llm's archived ollama fork

Source not public. Intel shipped `ollama-ipex-llm` as binary-only via "portable zip" releases and Docker images. The `intel/ipex-llm` repo (Apache-2.0, archived 2026-01-28) contains only docs, init scripts, and patches for vLLM/oneCCL — **zero ollama Go source**. The active continuation `github.com/ipex-llm/ipex-llm` is the same situation.

Implication: we cannot lift their integration. Have to write our own Go-side discovery and runner-dispatch patches against ollama. Their documented runtime-env recipe is reusable as a hint, though:

- `OLLAMA_NUM_GPU=999` — force-offload-all
- `ZES_ENABLE_SYSMAN=1` — Level Zero sysman (power/thermal queries)
- `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS` — perf
- `SYCL_CACHE_PERSISTENT=1` — cache JIT'd kernels across runs
- `ONEAPI_DEVICE_SELECTOR` — narrow to Level Zero / specific device
- Need `setvars.sh` (or LD_LIBRARY_PATH equivalent) — failure mode is `libsvml.so: cannot open shared object file`

### Intel oneAPI / DPC++ in nixpkgs

🎉 **`pkgs.intel-llvm` merged April 2026** via NixOS/nixpkgs#470035. It's `intel/llvm` upstream — the open-source DPC++/SYCL compiler that Intel rebrands as `icpx` in their proprietary distribution. Provides a custom SYCL stdenv. Author of the PR successfully built oneDNN against it.

Caveats:
- Pinned at `unstable-2025-11-14` (not a release tag) due to intel/llvm issue #19635.
- Does NOT expose `icpx` by name; exposes `clang++` from intel/llvm (same binary, no Intel branding).
- llama.cpp issue #14440 reports a build break on oneAPI 2025.2 (`isgreater` macro collision); 2025.1.1 works. Whether `intel-llvm@unstable-2025-11-14` (post-2025.2) inherits the bug is unverified — we have to test.
- Other oneAPI bits already in nixpkgs: `level-zero`, `oneTBB`, `oneMKL`, `oneDNN`, `oneVPL`. Missing: oneDPL/oneDAL/oneCCL/VTune.

If `intel-llvm` works for our case, **Phase 2 collapses from "package oneAPI from FOD" to "use existing nixpkgs package"** — multi-day effort dropped to ~30 min.

## Refined plan

1. **Verify** `intel-llvm` is in our pinned nixpkgs and can compile a SYCL hello-world targeting Level Zero. (running)
2. **Build llama.cpp from upstream `ec98e2002`** with `-DGGML_SYCL=ON` using `intel-llvm` stdenv. Validate toolchain end-to-end.
3. **Smoke-test on the B70**: `llama-cli --list-devices` should show "Intel(R) Arc(TM) Pro B70 Graphics" via Level Zero; small inference (Qwen2.5-7B) for sanity; 30B inference (Qwen2.5-32B Q4_K_M) to confirm the per-buffer cap is bypassed.
4. **Fork ollama**:
   - Copy `ggml-sycl/` from upstream `ec98e2002` into `ml/backend/ggml/ggml/src/ggml-sycl/`.
   - Patch `ml/backend/ggml/ggml/src/CMakeLists.txt` to enable the SYCL backend conditional.
   - Patch `discover/` Go code: add Level Zero device enumeration via cgo bindings to `libze_loader.so`.
   - Patch `discover/runner.go` to recognize a `sycl` runner directory and route Intel devices to it.
5. **Package** as `pkg/ollama-sycl/` overriding nixpkgs ollama.
6. **Wire into the ollama container**: replace `package = pkgs.ollama-vulkan` with `pkgs.ollama-sycl`; drop the GGML_VK_DISABLE_COOPMAT env vars (irrelevant under SYCL); add `ONEAPI_DEVICE_SELECTOR=level_zero:0`, `SYCL_CACHE_PERSISTENT=1`, `ZES_ENABLE_SYSMAN=1`, `GGML_SYCL_DISABLE_OPT=1` (workaround for ggml#21893).
7. **Test** with the gemma4 prompt that produced garbage on Vulkan, then a real 30B model (Qwen2.5-32B-Instruct Q4_K_M).

## Risks ranked

- **High**: ollama Go-side runner dispatch is undocumented internals; might need substantial tracing of how Vulkan integration works to mirror it for SYCL.
- **Medium**: `intel-llvm@unstable-2025-11-14` may hit the `isgreater` macro break on ggml-sycl source. Mitigation: vendor a patch from llama.cpp #14440 if needed.
- **Medium**: ggml-sycl on B70 itself may be flaky (open issue #21893 — `GGML_SYCL_DISABLE_OPT=1` is the documented workaround). PMZFX/intel-arc-pro-b70-benchmarks reports good numbers (24-32B at 21-30 t/s) so the path is known to work in principle.
- **Low**: Level Zero device enumeration via Go cgo. Standard pattern; intel-compute-runtime + level-zero already in nixpkgs.

## Decision points still open

- Should we vendor our patched ollama as a git submodule, a fetchFromGitHub of our own fork, or just an in-tree `pkg/ollama-sycl/source/` with patches applied via overlay? Lean toward "keep it in-tree under `pkg/ollama-sycl/patches/` so the source change is reviewable in `git diff`".
- Auto-detect SYCL devices vs require explicit env (`OLLAMA_LLM_LIBRARY=sycl`)? Lean toward explicit-only initially, auto-detect once stable.

## Phase 2-3 build pitfalls actually hit (record so we don't relitigate)

In order of discovery while making `pkg/llama-cpp-sycl/` build:

1. **`pkgs.intel-llvm` merged output is empty.** The package's symlinkJoin uses `__structuredAttrs = true;` and the build script `cat $pathsPath` → `$pathsPath` is unset under structuredAttrs in this nixpkgs. Fix: overlay-override `intel-llvm` to set `__structuredAttrs = false; passAsFile = ["buildCommand" "paths"]; paths = builtins.toString old.paths;` (in `globals.nix`).
2. **`pkgs.intel-compute-runtime` ships `libze_intel_gpu.so` in a separate `drivers` output.** Default `hardware.graphics.extraPackages` doesn't include `intel-compute-runtime.drivers`, so `/run/opengl-driver/lib/` is missing the L0 driver and SYCL's L0 v2 adapter segvs in `zeInitDrivers`. Fix: add `intel-compute-runtime.drivers` to extraPackages in `modules/nixos/intel-gpu.nix`.
3. **Even with the L0 driver present, `intel-compute-runtime 26.09.37435.1` aborts in its GMM helper** during L0 init on the B70 (`gmm_helper/resource_info.cpp:15` UNRECOVERABLE_IF). Workaround: ship `ONEAPI_DEVICE_SELECTOR=opencl:gpu` as the default. SYCL on top of OpenCL avoids the GMM init path and works correctly. Re-evaluate when intel-compute-runtime gets a version bump.
4. **`intel-llvm.stdenv` doesn't propagate the overlay-fix.** Its passthru `stdenv = overrideCC baseLlvm.stdenv self.merged` references the package-internal scope's merged, which is still the broken-empty derivation regardless of our overlay override. Fix: use plain `stdenv` in our derivation, depend on `intel-llvm` as `nativeBuildInput`, set `CC=${intel-llvm}/bin/clang CXX=${intel-llvm}/bin/clang++` in `preConfigure`.
5. **MKL 2023.1 only has `MKL::mkl_sycl` (legacy single target), not `MKL::MKL_SYCL::BLAS` (oneMKL 2024.1+ namespaced split).** ggml-sycl@ec98e2002 expects the namespaced one. Fix: postPatch substitution `MKL::MKL_SYCL::BLAS` → `MKL::mkl_sycl`.
6. **MKL detects DPC++ compiler by basename** (`CXX_COMPILER_NAME STREQUAL "icpx"|"dpcpp"|"icx"`). intel-llvm's binary is `clang++` so MKL leaves `DPCPP_COMPILER` off and never creates the `mkl_sycl` target at all. Fix: in preConfigure, symlink `$TMPDIR/intel-shim/bin/{icx,icpx} -> ${intel-llvm}/bin/{clang,clang++}`, point `CC/CXX` there.
7. **MKL needs `tbb` at build time** for its default `tbb_thread` threading mode. Fix: add `tbb` to `buildInputs`.

Build is in progress past all seven of the above as of last touch. If/when more pitfalls surface (link-time `MKL::mkl_sycl` symbol issues, ggml-sycl source incompatibilities with intel-llvm@unstable-2025-11-14, etc.), append below this list.

8. **MKL ↔ intel-llvm SYCL ABI version skew (BLOCKER as of 2026-05-03).** With everything else solved, link fails with hundreds of `undefined reference to sycl::_V1::*` symbols. nixpkgs `mkl@2023.1.0` was built against Intel oneAPI 2023.1's `libsycl.so` ABI; our `intel-llvm@unstable-2025-11-14` provides a newer `libsycl.so` with completely different symbol mangling. They cannot link regardless of patches. ggml-sycl on Intel has no opt-out — `find_package(MKL REQUIRED)` is unconditional in the INTEL branch (the NVIDIA/AMD branches use oneMath instead, but Intel doesn't because of [oneMath#654](https://github.com/uxlfoundation/oneMath/issues/654) static-linking issues). nixpkgs has only one MKL version. **Resolution: package a newer oneMKL via FOD that matches intel-llvm's SYCL ABI** (probably oneMKL 2024.2 or 2025.0; tracked as Phase 2.5 / task #9 in TaskList).

## Status as of 2026-05-03 end-of-session

- Phases 1, 2 done.
- Phase 3 (`pkg/llama-cpp-sycl/`) is a working derivation right up to the link step; compile path is solid, all 7 pitfalls above have working fixes in the derivation.
- Blocked on Phase 2.5 — packaging newer Intel oneMKL via FOD.
- Phases 4–8 unchanged: smoke-test on B70, fork ollama, copy ggml-sycl source, patch Go discovery, build ollama-sycl, swap into container.

If Phase 2.5 turns out to be too costly (e.g. Intel's offline installer fights nix purity in ways that take more than a couple evenings), the documented fallback is `intel/llm-scaler-vllm` Docker image — bypasses all the nix packaging chain in 30 minutes, costs a Docker layer.

## 2026-05-03 (later) — Phase 2.5 done, link succeeds

Packaged `pkg/mkl-sycl/` as a FOD pulling Intel's yum-repo `.rpm`s for oneMKL **2025.3.1** plus matching openmp/tbb. ABI matrix probed empirically:

| MKL release | `libmkl_sycl_blas.so` NEEDED |
|-------------|-------------------------------|
| 2023.1.0    | libsycl.so.6 (current nixpkgs `mkl`) |
| 2025.0–2025.3 | libsycl.so.8 ✓ matches intel-llvm |
| 2026.0      | libsycl.so.9 (would need intel-llvm bump) |

Wired in via overlay in `globals.nix` as a *sister* package to `mkl@2023.1.0` — global `mkl` is unchanged so numpy/scipy/octave aren't perturbed; only `llama-cpp-sycl` consumes the new MKL via `callPackage … { mkl = final.mkl-sycl; }`.

Build outcome: `nix build .?submodules=1#nixosConfigurations.vm.pkgs.llama-cpp-sycl` produces 42 binaries. `objdump -p $out/bin/.llama-cli-wrapped` shows clean NEEDED chain:

```
NEEDED libmkl_sycl_blas.so.5
NEEDED libmkl_intel_ilp64.so.2
NEEDED libmkl_intel_thread.so.2
NEEDED libmkl_core.so.2
NEEDED libiomp5.so
NEEDED libsycl.so.8
NEEDED libOpenCL.so.1
RUNPATH /nix/store/...-mkl-sycl-2025.3.1-8/lib:/nix/store/...-intel-llvm-.../lib:...
```

### Pitfalls hit in Phase 2.5 (record in case the FOD needs touch later)

1. **`'$''{MKLROOT}'` parses wrong in Nix indented strings.** `''$` escapes `$` and `''${` escapes `${`. Use `"''${MKLROOT}"` for a literal `${MKLROOT}` in the shell. Comments inside an indented string also need `${...}` escaped.
2. **Comment with `${CMAKE_CURRENT_LIST_DIR}` triggers Nix antiquotation.** Same fix — escape or rephrase the comment.
3. **MKLConfig.cmake's `find_package(TBB CONFIG)` fails even with nixpkgs `tbb.dev` available.** `MKL_SYCL_THREADING=tbb_thread` is the default and bails the whole `MKL::MKL_SYCL` target chain when TBB isn't found. nixpkgs' tbb.dev *does* have TBBConfig.cmake, but MKL doesn't seem to find it (suspected: MKLROOT-relative search bails before falling through). Workaround: `MKL_THREADING=intel_thread` + `MKL_SYCL_THREADING=intel_thread` via cmakeFlags. Uses `libiomp5.so` from our `mkl-sycl/lib/`. CPU threading mode is irrelevant for GPU SYCL workloads — only matters for kernel launches.
4. **`find_package(IntelSYCL)` fails (no `IntelSYCLConfig.cmake` in intel-llvm).** Non-fatal — ggml-sycl has a fallback path that just emits `-fsycl` compile/link options. Warning is loud but harmless.

### Pitfalls *avoided* by going to MKL 2025.3 (vs 2023.1)

- 2025.3 ships the `MKL::MKL_SYCL::BLAS` namespaced target natively. Drop the `MKL::MKL_SYCL::BLAS → MKL::MKL_DPCPP` postPatch substitution from llama-cpp-sycl.
- 2025.3's MKLConfig.cmake has a fallback `-fsycl` flag check for non-Intel-branded compilers (the icx/icpx symlink shim still works fine and we keep it as cheap insurance against regressions).

### Updated phase status

- Phases 1, 2 ✅ (toolchain).
- Phase 2.5 ✅ (oneMKL 2025.3.1 packaged).
- Phase 3 ✅ (`pkg/llama-cpp-sycl/` builds & links).
- Phase 4 (smoke-test on B70 — `llama-cli --list-devices`, then 7B inference, then 30B): pending. Test script staged at `/tmp/exchange/sycl-smoke/test.sh` — needs to run on the host (sandbox lacks `/dev/dri`).
- Phases 5–8: unchanged (fork ollama, copy ggml-sycl, patch Go discovery, build ollama-sycl, container swap).

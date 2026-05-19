# Roadmap: ollama-sycl running on Intel Arc Pro B70 under Level Zero

**Goal**: deployed `ollama-sycl` daemon on the `vm` host uses Level Zero
(not OpenCL) as the SYCL UR backend, with the maximum practical reduction
of vendored llama.cpp / ggml source.

**Anchor evidence collected 2026-05-19**:

- `pkg.llama-cpp-sycl@ad09224` on L0 passed all 9 architecture tests
  (`tests/test-llama-cli.sh` against HF GGUFs): qwen2, qwen3, qwen3.5,
  gemma3, glm4, gpt-oss (MXFP4 + bf16), llama, ministral. Throughput
  range 14–180 t/s pp, 14–113 t/s tg. All generate coherent tokens.
  → SYCL kernels + intel-compute-runtime 26.18 + intel-llvm DPC++ +
  level-zero loader stack are healthy on B70.
- Production `ollama-sycl@073bb2c20` daemon is **currently broken**.
  Wrapped with `ONEAPI_DEVICE_SELECTOR=opencl:gpu`. After the host
  redeploy that bumped intel-compute-runtime to 26.18 and intel-llvm
  to unstable-2025-11-14, **both qwen3:4b (legacy llamarunner) and
  qwen3.5:9b (new ollama-engine) return `model failed to load`** —
  not a single generate succeeds. Daemon comes up healthy (`/api/tags`
  works, 40 models indexed) but cannot run any of them. This blocks
  the user's actual workload and makes Phase 1 urgent, not optional.
- L0 path has never been exercised end-to-end on ollama-sycl even
  after the ICR 26.09 → 26.18 bump that fixed the original
  GMM-helper-aborts-on-L0-init issue. Phase 1 is the cheapest way to
  find out if L0 unblocks the deployed daemon.
- Stock `llama-cli` cannot load ollama-store GGUFs (qwen3.5/3.6/glm/
  gpt-oss/gemma4/ministral-3) — ollama emits with arch-name and
  metadata variants its own Go engine reads, e.g. `glm4moelite` vs
  upstream `glm4moe`, `qwen35.rope.dimension_sections` 3 vs 4. ollama
  GGUFs are a one-way format; conversion tooling doesn't exist.
- Patch 0030 (No-alloc mode full port for ad09224) introduces a
  `GGML_ASSERT(tensor->buffer == NULL)` crash even CPU-only — must be
  re-ported or kept as stub.

**Prior art preserved as `git stash@{0}`** (`WIP on main: 1a539b2`).
316 files, +14132/-38880. Contains the complete unvendoring attempt
from this session that got partial completion before being parked:

- `pkg/ollama-sycl/default.nix` rewritten to consume `llama-cpp-sycl`
  as a buildInput, default `syclBackend = "level_zero"`, postInstall
  + patchelf RPATH wiring for `libggml-sycl.so`.
- llama.cpp@ad09224 vendored under `pkg/ollama-sycl/ollama-src/`
  with 5 ollama patches ported (0024 GPU UUIDs, 0025 batch-size hint,
  0030 no-alloc mode FULL — **broken, keep as stub from 0026 instead**,
  0031 dev reset, 0032 GPU discovery enhancements).
- `ml/backend/ggml/ggml/src/ggml-sycl/` subtree deleted (1000+ files,
  the bulk of the -38880).
- SYCL-specific patches in `llama/patches/` removed (now live in
  `pkg/llama-cpp-sycl/patches/`).
- `ggml-ext.h` reduced to a thin `#include "ggml-backend.h"` shim
  (upstream ad09224 promoted all the "staging" types into the public
  header).
- `tests/test-llama-cli.sh` HF-flavoured matrix (also in stash).

State at park: builds clean. CPU-only inference works after reverting
patch 0030. **SYCL backend loads as a plugin but its `ggml_backend_*`
registrations land in a different ggml-base instance than the runner's
static one, so it's invisible to inference.** This is the
static-vs-dynamic ggml-base split documented in Phase 3.

When restoring with `git stash pop stash@{0}`, expect merge conflicts
in `pkg/llama-cpp-sycl/default.nix` (committed in `1a539b2` after
stash creation) and `tests/test-llama-cli.sh` (rewritten to consume
HF GGUFs from `debug/hf-ggufs/` in a follow-up). The conflicts are
mechanical.

**Out of scope for this roadmap** (forks ollama in earnest):

- Unvendoring `ml/backend/ggml/src/models/` — these are ollama's
  first-party Go implementations of model architectures. They are not
  derived from llama.cpp's `src/models/`; they are a parallel Go port.
  Removing them = abandoning ollama-engine support, which is the very
  feature the user pulled qwen3.5/3.6/glm/gpt-oss for.

---

## Phase 1 — Minimum viable: vendored ollama-sycl on L0 (cheap, fast)

Validate that the **deployed** ollama-sycl can run on L0 just by
flipping the wrapper env. No code changes to ollama-sycl itself.

This is the first thing to do because it's the cheapest source of
empirical data, and if it works we may already meet the user's
practical need without any further engineering.

### Steps

1. **Build a one-off ollama-sycl variant with `syclBackend = "level_zero"`.**
   The argument already exists in `pkg/ollama-sycl/default.nix` (see
   the `syclBackend ? "opencl"` parameter). Override it in the host
   config:
   ```nix
   # private/hosts/vm/cfg-vm.nix or wherever the package is wired:
   services.ollama-sycl.package = pkgs.ollama-sycl.override {
     syclBackend = "level_zero";
   };
   ```
   Alternatively, override the env at the systemd unit level
   (`Environment="ONEAPI_DEVICE_SELECTOR=level_zero:0"` etc.) to avoid
   a rebuild.

2. **Validate the runner discovers the L0 device.**
   ```
   journalctl -u container@ollama -f
   ```
   Look for `inference compute id=cpu library=cpu` (bad) vs
   `inference compute id=SYCL0 library=SYCL` (good). If it stays
   `id=cpu`, the dual-instance ggml registry issue we mapped earlier
   is biting and Phase 1 is blocked; jump to Phase 3.

3. **Validate inference works on a handful of models.**
   `curl -d '{"model":"qwen3.5:9b","prompt":"hi","stream":false}' …`
   for each of: qwen3.5:9b, qwen3.6:27b, qwen3.6:latest,
   glm-4.7-flash:latest, gpt-oss:20b, gemma4:e4b, ministral-3:14b.
   Compare throughput to OpenCL baseline.

### Success criteria
- `inference compute … library=SYCL` in the daemon log on startup
- All 7 models above generate coherent tokens
- tg t/s at least matches OpenCL (expect 2× faster per
  `pkg/llama-cpp-sycl` measurements)
- No SIGSEGV in `journalctl --since "1 hour ago"` for the
  `container@ollama` unit

### Known risks
- **Most likely blocker**: ollama runner's static-ggml registry
  doesn't include the dynamically-loaded SYCL backend. Symptom:
  daemon comes up but only sees CPU. → Phase 3.
- Less likely: the ad09224 SYCL fixes are needed to handle some op
  on these models, in which case L0 crashes on first dispatch like
  it did pre-bump for qwen3 — needs Phase 2.

### Effort
~1 hour, including the rebuild + container respawn + matrix.

---

## Phase 2 — Unvendor the SYCL backend (consume `libggml-sycl.so` from `pkg.llama-cpp-sycl`)

Replace ollama-sycl's internal `-DGGML_SYCL=ON` compile with the
externally-built plugin from `pkg.llama-cpp-sycl`. Drop the entire
`ml/backend/ggml/ggml/src/ggml-sycl/` source tree (1000+ files) from
the vendored tree. Drop the SYCL-specific Hal9000 + IGC postPatches —
they live in `pkg/llama-cpp-sycl` already.

Achievable in isolation **if Phase 1 worked** (single ggml backend
registry, no static-vs-dynamic split).

**Start from `git stash@{0}`**, which has 95% of this phase already
done. Workflow:

```
git stash pop stash@{0}
# Resolve mechanical conflicts in:
#   pkg/llama-cpp-sycl/default.nix       (already committed)
#   tests/test-llama-cli.sh              (rewritten to consume HF GGUFs)
# Revert patch 0030 (it's broken — keep stub 0026)
patch -R -p1 -d pkg/ollama-sycl/ollama-src/ml/backend/ggml/ \
  < pkg/ollama-sycl/ollama-src/llama/patches/0030-…patch
rm pkg/ollama-sycl/ollama-src/llama/patches/0030-…patch
nix build .?submodules=1#nixosConfigurations.vm.pkgs.ollama-sycl
```

Most of the Phase-2 steps below are already implemented in the stash;
this list is for review when you cherry-pick or redo the work from
scratch.

### Steps

1. **In `pkg/ollama-sycl/default.nix`**:
   - Add `llama-cpp-sycl` to `buildInputs`.
   - Pass `-DGGML_SYCL=OFF -DOLLAMA_ENABLE_SYCL=OFF` to the cmake
     preBuild invocation.
   - Drop `mkl`, `oneDNN`, `tbb`, MKL_THREADING, MKLROOT,
     hardeningDisable, the bf16-IMF + memcpy postPatches, and the
     `-isystem ${intel-llvm}/include` preConfigure. All are SYCL
     compile prerequisites; with internal SYCL compile gone they
     become dead weight.
   - Add postInstall: `install -Dm0755 -t $out/lib/ollama/sycl/
     ${llama-cpp-sycl}/bin/libggml-sycl.so`. ollama's runtime backend
     loader (`ggml_backend_load_all_from_path`) finds it via
     OLLAMA_LIBRARY_PATH at startup.
   - Patchelf the plant: `patchelf --set-rpath '$ORIGIN/..:<orig>'
     libggml-sycl.so` so it resolves `libggml-base.so.0` against the
     ollama-built copy in `$out/lib/ollama/`, not the LCS copy.
     Otherwise two `libggml-base.so` instances coexist in memory →
     double-init warnings (and possibly worse).

2. **In `pkg/ollama-sycl/ollama-src/llama/llama.cpp/`**:
   - Delete `ggml/src/ggml-sycl/` (the upstream SYCL backend source
     tree, 1000+ files) — never compiled with `GGML_SYCL=OFF`, so
     it's dead.
   - Add a `.rsync-filter` entry under
     `ml/backend/ggml/ggml/src/ggml-sycl/` so the next `make sync`
     doesn't bring it back.
   - Delete `llama/patches/0023-sycl-route-small-f32-matmuls-…patch`
     and any other SYCL-only patches in the series — they live in
     `pkg/llama-cpp-sycl/patches/` as the single source of truth.
   - **Critically: `git rm --cached` everything you delete on disk**,
     otherwise `nix flake .?submodules=1` materializes the staged-add
     ghosts from the index back into the build sandbox. See
     `feedback_git_index_ghost_add.md` for the trap from earlier.

3. **Rebuild + retest the Phase 1 matrix.**

### Success criteria
- ollama-sycl's source tree under `pkg/ollama-sycl/ollama-src/` is
  smaller by ~1000 files (the `ggml-sycl/` subtree) + ~12 SYCL
  patches in `llama/patches/`.
- Daemon log shows the SYCL backend loaded from the LCS-shipped path
  under `$out/lib/ollama/sycl/libggml-sycl.so`, with no
  "double registration" warnings.
- Phase 1 matrix still passes.

### Known risks
- **Build-mode mismatch**: the ollama runner is built with cgo
  static-linking ggml-base; the plugin uses dynamic ggml-base from
  its own DT_NEEDED. Two `ggml-base` instances in process; backend
  registrations go to one but the runner reads from the other.
  Symptom: ggml's `register_ggml_backend()` warning "double
  registration of ggml_uncaught_exception", followed by SYCL backend
  being invisible to the runner's `ggml_backend_dev_count()`. → Phase 3.
- The ollama runner may have its own ggml-sycl bindings (cgo headers)
  that no longer have a corresponding `.cpp` to compile. If
  `ml/backend/ggml/sycl/*.go` exists and assumes ggml-sycl is built
  in-tree, it'll fail to link.

### Effort
~2–4 hours including troubleshooting and matrix re-validation.
Skipped previously due to the static-vs-dynamic ggml issue (Phase 3).

---

## Phase 3 — Fix the static-vs-dynamic ggml-base split (the hard architectural one)

The blocker found in this session. Ollama's runner cgo-builds
ggml-base symbols *statically* into `.ollama-wrapped`. Any plugin
`.so` (`libggml-cpu-*.so`, `libggml-sycl.so`) loaded via
`ggml_backend_load_all_from_path` brings its own libggml-base.so via
DT_NEEDED → two instances of the backend registry → plugin's
`ggml_backend_register()` lands in the plugin's registry, not the
runner's → SYCL device invisible to the runner.

Upstream nixpkgs ollama exhibits the same split but ships only CPU
backend plugins, and its runner's static ggml has its own CPU
backend registered, so the dual-instance state is benign. For us it
isn't because we want the SYCL plugin's registration to **reach the
runner**.

### Three sub-strategies, ranked best-to-worst

#### 3a. Force runner to dynamically link ggml-base via cgo LDFLAGS

Modify `ml/backend/ggml/ggml/src/ggml.go`'s cgo directives to:
- Add `#cgo LDFLAGS: -L${OUT}/lib/ollama -lggml-base -lggml-cpu` so
  the cgo linker resolves ggml-base from the shared lib at link time.
- Remove the in-tree `ggml*.cpp` source files from the cgo-scanned
  directory so cgo doesn't also static-compile them. Move them to a
  subdir cgo can't see, e.g. `cgo_internal/`, and add the parent dir
  to `#cgo CPPFLAGS` so header lookups still work.

Result: runner has zero ggml-base symbols statically; everything
resolves to the lib/ollama/libggml-base.so loaded at runtime. Plugin
.so files see the same instance. Single registry. Done.

**Risk**: invasive to ollama's cgo build conventions; future `make
sync` from upstream ollama will fight this. Maintainability cost.

#### 3b. Export the runner's static ggml symbols dynamically, drop plugin's libggml-base DT_NEEDED

Cgo LDFLAGS: `-Wl,--export-dynamic` to lift the static ggml symbols
into the runner's dynamic symbol table. Then `patchelf --remove-needed
libggml-base.so.0 libggml-sycl.so` so the plugin doesn't bring its
own. Plugin's undefined ggml_* refs resolve to the runner's exports
at dlopen time.

Tried this in the session. Got the plugin's `ggml_backend_register`
to reach the runner's registry (verified via LD_DEBUG=symbols,bindings:
`binding file libggml-sycl.so to .ollama-wrapped: normal symbol
ggml_backend_sycl_reg` — registration succeeds). But then the runner
crashed at `ggml_backend_reg_get_proc_address` with `%rax` containing
string-shaped data — function pointer in `reg->iface.get_proc_address`
not pointing at code. **Undiagnosed**.

Hypothesis: with the plugin no longer having a libggml-base.so
DT_NEEDED, some implicit constructor in libggml-base that the plugin
relies on never runs (the plugin's static initializer constructs its
own backend reg struct using helpers from libggml-base; if those
helpers aren't initialized, the struct is malformed). Needs a gdb
session at runner-subprocess `/info` handler entry to inspect the
plugin's `ggml_backend_sycl_reg` struct contents.

**Risk**: ABI subtleties on top of cgo+go-runtime symbol semantics.
Half a day of debugger work.

#### 3c. Build the runner with no plugin loading at all (vendor SYCL back in)

Give up unvendoring; flip back to Phase 1's mode (internal SYCL
compile). Phase 1 alone may be sufficient for the user's needs.

### Success criteria (3a or 3b)
- Runner subprocess `/info` handler returns >0 SYCL devices when
  libggml-sycl.so is in `$OLLAMA_LIBRARY_PATH/sycl/`.
- Daemon's `inference compute` log line shows `library=SYCL`.
- Phase 1 matrix passes.

### Effort
- 3a: ~1 day, including upstream-sync churn defense
- 3b: half a day if the gdb session is productive; could be longer if
  the root cause is deeper
- 3c: 0 effort, accept Phase 1 as terminal

---

## Phase 4 — Unvendor `libllama` + `libggml-base` (system-wide llama.cpp)

Only meaningful if Phase 3 succeeded. Replace the entire
`ml/backend/ggml/ggml/` subtree under `pkg/ollama-sycl/ollama-src/`
with `#cgo CPPFLAGS: -I${pkg.llama-cpp-sycl.dev}/include` plus
`#cgo LDFLAGS: -L${pkg.llama-cpp-sycl}/lib -lggml-base -lggml-cpu
-lllama`. Same logic for `llama/llama.cpp/common/`,
`llama/llama.cpp/tools/mtmd/`.

This is **only the ggml runtime + libllama loader**. The Go
implementations under `model/models/` (ollama-engine's qwen35,
qwen35moe, glm4moelite, gptoss, mistral3, gemma4) stay where they
are — those are ollama's first-party code.

### Steps

1. Move ollama's customizations to `common/*.cpp`, `tools/mtmd/*.cpp`
   into out-of-tree patches against pkg.llama-cpp-sycl's source.
2. Replace `ml/backend/ggml/ggml/` with a flake input pointing at
   pkg.llama-cpp-sycl's `${src}/ggml/`.
3. Wire cgo to system-installed libllama via pkg-config.

### Success criteria
- `pkg/ollama-sycl/ollama-src/` shrinks from ~50k files to ~5k
  (just the Go code + ollama's own model implementations).
- Builds use `pkg.llama-cpp-sycl`'s sources as a build input, not a
  vendored copy.
- All Phase 1 + 2 + 3 tests still pass.

### Known risks
- Ollama's vendored llama.cpp has post-sync edits beyond what's in
  the `llama/patches/` series — silent fixups applied during the
  tree-prep flow. Externalizing those means converting each into a
  reviewable patch. Significant archeology.
- Upstream llama.cpp moves fast. Every weekly `nixpkgs ollama` bump
  may require re-syncing the patch series.

### Effort
~2–5 days if Phase 3 worked. Realistic. Less if we drop ollama-engine
support and use only the legacy `llamarunner` path (then we don't
need ollama's `model/models/` — just stock llama-cli style loading).

---

## Recommendation: do Phase 1 first, but urgency is now higher

Phase 1 was originally framed as "cheap validation". The post-redeploy
discovery that **every model on the deployed daemon now fails to
load** means Phase 1 is also the most plausible **incident fix**:
the OpenCL path the deployed daemon takes is the one that broke when
intel-llvm + intel-compute-runtime got bumped under it, while L0 +
the new stack is empirically healthy via `llama-cpp-sycl`. Flipping
to L0 has good odds of restoring service.

Three productive outcomes for Phase 1:

- **Best**: daemon works on L0 across the model matrix → close out
  the incident, Phase 2-4 stay as nice-to-have refactors.
- **Middle**: daemon's runner sees L0 device but inference still
  fails — narrows the issue to ggml-sycl behavior against the new
  stack, points at specific patches to backport from ad09224.
- **Worst**: runner doesn't see L0 device at all (`library=cpu`
  in the log) → that's the static-vs-dynamic ggml split rearing its
  head pre-unvendoring, which is unexpected (the in-tree ggml-sycl
  shouldn't trigger it) and worth investigating before assuming
  Phase 3 work.

Then Phase 2 from `git stash@{0}` (already ~95% done). Then Phase 3
sub-strategy choice based on Phase 2 results. Phase 4 stays
opportunistic.

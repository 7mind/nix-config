# ollama-sycl, whole-tree-bumped variant.
#
# Sister derivation to ./default.nix. Difference:
#
#   default.nix     — surgically splices llama.cpp@15bff84's `ggml-sycl/`
#                     into ollama 0.23.0's vendored ggml (which is from
#                     llama.cpp@ec98e2002). Works for qwen2/qwen3 but
#                     qwen35* SIGSEGVs in the new ollama-engine SYCL
#                     dispatch path; the older 15bff84 ggml-sycl predates
#                     the new-engine fixes for that arch.
#
#   whole-tree.nix  — bumps the ENTIRE vendored llama.cpp tree to
#                     073bb2c20 (Apr 2026, same commit our pkg/llama-cpp-sycl
#                     uses), with all 36 ollama patches reapplied + 8
#                     Hal9000 SYCL patches + PR #16036's SYCL discovery
#                     wiring. Tree was prepared off-derivation in
#                     /tmp/exchange/ollama-main and snapshotted into
#                     `./ollama-src/` (44 patches, all post-rsync
#                     adaptations: llama_set_adapters_lora, common_grammar
#                     ctor, props.memory_free, batch_size graph_compute
#                     param, set_rows.cpp bf16 IMF bypass, src/models/
#                     and common/ CGO include paths). See
#                     project_ollama_sycl_fork.md for the full tree-prep
#                     log.
#
# Why a separate derivation rather than a flag on default.nix: A/B
# testing. We keep default.nix as the known-good qwen2/qwen3 path while
# we burn in whole-tree. Once whole-tree proves out qwen35 inference, we
# may collapse the two.
{
  lib,
  ollama,
  stdenv,
  intel-llvm,
  intel-compute-runtime,
  level-zero,
  ocl-icd,
  opencl-headers,
  mkl-sycl,
  oneDNN,
  tbb,
  cmake,
  pkg-config,
  makeWrapper,
  perl,
}:

ollama.overrideAttrs (oldAttrs: {
  pname = "ollama-sycl-whole-tree";
  version = "0.23.0-whole-tree+073bb2c20";

  # The whole-tree-bumped source. This is the post-`make sync` working
  # tree, NOT a clean upstream snapshot — the 36 ollama patches and 8
  # Hal9000 SYCL patches are already applied to the vendored llama.cpp
  # under `ml/backend/ggml/ggml/src/`. Patch *files* are kept under
  # `llama/patches/` for reference but are not re-applied at build time
  # (mirrors how upstream nixpkgs ollama treats its own tagged
  # tarballs).
  src = ./ollama-src;

  # vendorHash will differ from upstream ollama 0.23.0 because the bump
  # touched go.mod indirectly (CGO header search paths in src/models/
  # and common/, plus the tree-prep flow re-tidied modules). Compute
  # via the standard "set fakeHash, build, copy real hash from error,
  # paste here" dance. If the build's `goModules` derivation succeeds
  # against this hash, the source is internally consistent.
  vendorHash = "sha256-Lc1Ktdqtv2VhJQssk8K1UOimeEjVNvDWePE9WkamCos=";

  nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [
    cmake
    pkg-config
    makeWrapper
    perl
  ];

  # See default.nix for the buildInputs-vs-nativeBuildInputs rationale
  # — intel-llvm's setup-hook only fires for host-role buildInputs.
  buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
    intel-llvm
    intel-compute-runtime
    level-zero
    ocl-icd
    opencl-headers
    mkl-sycl
    oneDNN
    tbb
  ];

  # Ride upstream nixpkgs ollama's postPatch (version/version.go bump,
  # cmd/launch test substitutions, `rm -r app`). Then add our SYCL-side
  # adjustments. None of the splicing/preset/CMake-block injection from
  # default.nix is needed here — the whole-tree source already has:
  #   - `ml/backend/ggml/ggml/src/ggml-sycl/` (rsynced from 073bb2c20)
  #   - PR #16036's SYCL discovery wiring in the root CMakeLists.txt
  #     (option OLLAMA_ENABLE_SYCL → GGML_SYCL=ON, install(TARGETS
  #     ggml-sycl) block guarded by `if(TARGET ggml-sycl)`)
  #   - bf16 IMF bypass in `set_rows.cpp` (verified: grep for
  #     `is_same_v<TOut, sycl::ext::oneapi::bfloat16>` returns 1)
  #   - HOST_MEM_FALLBACK CMake option from Hal9000 patch #8 (verified:
  #     grep for `GGML_SYCL_HOST_MEM_FALLBACK` returns 3 matches in
  #     ggml-sycl/CMakeLists.txt)
  postPatch = (oldAttrs.postPatch or "") + ''
    # Force the dense Qwen3 / Qwen3.5 family onto the legacy llama.cpp
    # runner. The new ollama-engine SIGSEGVs in
    # `ggml_backend_sched_graph_compute_async` on first prompt for these
    # archs — verified empirically against qwen36-27b on 2026-05-08.
    # The crash repro'd with both 15bff84 and 073bb2c20 ggml-sycl, so
    # the defect lives in the new-engine Go scheduler, NOT in
    # ggml-sycl.
    #
    # Legacy llama.cpp@073bb2c20 (this whole-tree's vendored copy) has
    # full LLM_ARCH_QWEN35 + LLM_ARCH_QWEN35MOE support via
    # `src/models/qwen35moe.cpp` + `llm_build_delta_net_base` —
    # demonstrated working via `llama-cli`/`llama-server` in
    # pkg/llama-cpp-sycl at this same commit (Qwen3.5/3.6 inference at
    # 17–48 t/s). So routing qwen35* to legacy bypasses the new-engine
    # bug while keeping SYCL acceleration.
    #
    # Leave qwen3next / qwen3vl / qwen3vlmoe on the new engine: those
    # need its Mamba-SSM + vision support that legacy llama.cpp lacks.
    # Leave qwen25vl on the new engine for the same reason.
    # 2026-05-08: legacy-runner routing was the wrong call for whole-tree.
    # llama_decode in legacy SIGSEGVs even after the output_all=false fix
    # (residual issue we couldn't pin down). Leave qwen35* on the new
    # ollama-engine path — at 073bb2c20 with the bumped ggml-sycl that
    # has more SYCL kernel fixes than the surgical-splice's 15bff84,
    # the original new-engine SIGSEGV in graph_compute_async may now
    # work.
    echo "ollama-sycl-whole-tree: leaving OllamaEngineRequired untouched (qwen35* via new engine)"

    # Force device-side `memcpy` calls in `ggml-sycl/dequantize.hpp` to
    # use `__builtin_memcpy` instead. IGC (Intel Graphics Compiler)
    # cannot resolve a plain `memcpy` external symbol when JIT-ing
    # SPIR-V kernels at runtime — the SPV-validation phase fails with
    # `unresolved external symbol memcpy at offset … in instructions
    # segment #N (aka kernel : ...dequantize_q5_0...)`. This kills the
    # ollama legacy runner during eager kernel registration even
    # though the model is Q4_K_M (the q5_0 / q5_1 / mxfp4 dequant
    # template instantiations are link-pulled in regardless of the
    # actual model's quant types). `__builtin_memcpy` gets inlined by
    # clang at the call site so IGC never sees an external symbol.
    #
    # Why not in pkg/llama-cpp-sycl/: the same source builds fine for
    # `llama-cli`/`llama-server` because those test paths only ever
    # used Q4_K_M models that never lazy-JIT the q5_*/mxfp4 dequant
    # kernels. Ollama's legacy runner is more aggressive about
    # registering all dequantize variants at startup, so it trips this
    # the moment it starts. Add the same patch to pkg/llama-cpp-sycl
    # if/when it's tested with q5_* or mxfp4 models.
    perl -i -pe '
      s{^(\s*)memcpy\(&qh, x\[ib\]\.qh, sizeof\(qh\)\);}
       {$1__builtin_memcpy(&qh, x[ib].qh, sizeof(qh));}
    ' ml/backend/ggml/ggml/src/ggml-sycl/dequantize.hpp
    grep -q '__builtin_memcpy(&qh, x\[ib\]\.qh' ml/backend/ggml/ggml/src/ggml-sycl/dequantize.hpp \
      || (echo "device-side memcpy substitution did not apply to dequantize.hpp"; exit 1)

    # Same fix for `ggml_sycl_e8m0_to_fp32` (mxfp4 dequant inner) and
    # the `cpy_blck_f32_q5_{0,1}` block-quant copy helpers — both
    # `__dpct_inline__`-class functions called from SYCL kernels, both
    # use `memcpy(...)` to bit-cast scalar values without breaking
    # strict aliasing. JIT picks them up through `dequantize_row_mxfp4_sycl`
    # / GGML_OP_CPY for q5_0 / q5_1 quant types.
    perl -i -pe '
      s{^(\s*)memcpy\(&result, &bits, sizeof\(float\)\);}
       {$1__builtin_memcpy(&result, &bits, sizeof(float));}
    ' ml/backend/ggml/ggml/src/ggml-sycl/common.hpp
    grep -q '__builtin_memcpy(&result, &bits, sizeof(float));' ml/backend/ggml/ggml/src/ggml-sycl/common.hpp \
      || (echo "device-side memcpy substitution did not apply to common.hpp"; exit 1)

    perl -i -pe '
      s{^(\s*)memcpy\(dsti->qh, &qh, sizeof\(qh\)\);}
       {$1__builtin_memcpy(dsti->qh, &qh, sizeof(qh));}
    ' ml/backend/ggml/ggml/src/ggml-sycl/cpy.hpp
    [ "$(grep -c '__builtin_memcpy(dsti->qh' ml/backend/ggml/ggml/src/ggml-sycl/cpy.hpp)" = "2" ] \
      || (echo "device-side memcpy substitution in cpy.hpp expected 2 hits"; exit 1)

    # Upstream PR #22035 / commit 788fcbc5 (Apr 20 2026) — fixes
    # `GGML_ASSERT(block_num_y % num_subgroups == 0)` in the four reorder
    # mul_mat_vec_q dispatchers (Q4_0, Q8_0, Q4_K, Q6_K). 073bb2c20 is
    # 2 weeks older than the fix, so the assertion still trips here on
    # any model whose output projection has nrows not divisible by 16
    # (Granite 3.0 / HY-MT / etc). Same patch file as pkg/llama-cpp-sycl
    # since the base commit is identical — one source of truth.
    patch -p4 -d ml/backend/ggml/ggml/src/ggml-sycl \
      < ${../llama-cpp-sycl/patches/0009-SYCL-Fix-reorder-MMVQ-assert-on-unaligned-vocab-size.patch}
  '';

  # FORTIFY workaround — see default.nix and project_ollama_sycl_fork.md.
  # IGC has no `__memcpy_chk` symbol so SYCL kernel JIT fails when ggml-sycl's
  # dpct/helper.hpp `std::memcpy` gets the FORTIFY-checked variant. Disabling
  # via cc-wrapper hardening (this attribute) actually removes the
  # `-D_FORTIFY_SOURCE=2` injection, unlike CMake-level
  # `target_compile_options(... -D_FORTIFY_SOURCE=0)` which loses the race
  # against the wrapper.
  hardeningDisable = (oldAttrs.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];

  # Same Go test issue as default.nix — `integration/` has all
  # build-tag-gated files which `go test ./...` reports as
  # `[setup failed]`. doInstallCheck still runs the version probe.
  doCheck = false;

  # See default.nix — intel-llvm's setup-hook is observed not to add the
  # -isystem flag under buildGoModule's cc-wrapper. Force it here.
  preConfigure = (oldAttrs.preConfigure or "") + ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -isystem ${intel-llvm}/include"
  '';

  MKLROOT = mkl-sycl;

  # Override upstream's preBuild (which is plain `cmake -B build`) with
  # one that enables SYCL. No CMakePresets.json SYCL preset exists in
  # the bumped tree — PR #16036 wired SYCL via root CMakeLists.txt
  # `option(OLLAMA_ENABLE_SYCL ...)` instead. Set it directly via
  # `-D`, plus OLLAMA_RUNNER_DIR=sycl so the install target lands in
  # `lib/ollama/sycl/` (matches the Vulkan/CUDA flavor convention).
  preBuild = ''
    mkdir -p $TMPDIR/intel-shim/bin
    ln -sf ${intel-llvm}/bin/clang   $TMPDIR/intel-shim/bin/icx
    ln -sf ${intel-llvm}/bin/clang++ $TMPDIR/intel-shim/bin/icpx
    export CC=$TMPDIR/intel-shim/bin/icx
    export CXX=$TMPDIR/intel-shim/bin/icpx
    export PATH=$TMPDIR/intel-shim/bin:$PATH

    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SKIP_BUILD_RPATH=ON \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DCMAKE_VERBOSE_MAKEFILE=ON \
        -DOLLAMA_ENABLE_SYCL=ON \
        -DGGML_SYCL=ON \
        -DGGML_SYCL_F16=ON \
        -DGGML_SYCL_TARGET=INTEL \
        -DGGML_SYCL_GRAPH=OFF \
        -DGGML_SYCL_DNN=ON \
        -DGGML_SYCL_HOST_MEM_FALLBACK=ON \
        -DMKL_THREADING=intel_thread \
        -DMKL_SYCL_THREADING=intel_thread \
        -DOLLAMA_RUNNER_DIR=sycl

    cmake --build build -j $NIX_BUILD_CORES
  '';

  # Same SYCL runtime defaults as default.nix. SYCL_CACHE_PERSISTENT=0
  # is load-bearing — see default.nix for the full rationale (NULL-deref
  # in libsycl.so.8 `getSortedImages` triggered via the persistent
  # disk-cache lookup path on first kernel JIT). Setting it to 0 bypasses
  # `getItemFromDisc` entirely.
  postFixup = (oldAttrs.postFixup or "") + ''
    if [ -e $out/bin/ollama ]; then
      wrapProgram $out/bin/ollama \
        --set-default ONEAPI_DEVICE_SELECTOR opencl:gpu \
        --set-default OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors \
        --set-default SYCL_CACHE_PERSISTENT 0 \
        --set-default ZES_ENABLE_SYSMAN 1
    fi
  '';

  meta = (oldAttrs.meta or { }) // {
    description = "Ollama with SYCL backend (whole-tree-bumped to llama.cpp@073bb2c20 for qwen35* support)";
  };
})

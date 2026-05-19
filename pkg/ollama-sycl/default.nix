# ollama-sycl: ollama with the GGML SYCL backend wired in for the Intel
# Arc Pro B70 (Battlemage / Xe2).
#
# Vendors the ENTIRE upstream llama.cpp tree at commit 073bb2c20 (Apr 2026,
# same commit our pkg/llama-cpp-sycl uses), with all 36 ollama patches
# reapplied + 8 Hal9000 SYCL patches + PR #16036's SYCL discovery wiring
# already present in the snapshotted source. Tree was prepared
# off-derivation in /tmp/exchange/ollama-main and snapshotted into
# `./ollama-src/` (44 patches, all post-rsync adaptations:
# llama_set_adapters_lora, common_grammar ctor, props.memory_free,
# batch_size graph_compute param, set_rows.cpp bf16 IMF bypass,
# src/models/ and common/ CGO include paths). See
# project_ollama_sycl_fork.md for the full tree-prep log.
#
# Earlier surgical-splice variant (only ggml-sycl/ replaced, ggml-base
# left at ollama's ec98e2002 vendor) is retired — silent struct/ABI
# mismatch between ggml-base and a newer ggml-sycl produced repetitive
# garbage tokens (Feb-2026 fc0fe40 bump attempt). Whole-tree avoids that
# by construction: ggml-base and ggml-sycl come from the same commit.
# Validated 2026-05-12 on B70 across granite-guardian 2b/8b, granite3.3
# 8b, qwen3.5 2b dense, qwen3.5 35b-a3b MoE (qwen35moe arch), qwen3.6
# 27b dense, gemma4 e4b, gemma4 26b — all generate coherent tokens via
# the new ollama-engine path.
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
  pname = "ollama-sycl";
  version = "0.23.0+llama-cpp-073bb2c20";

  # Vendored source — post-`make sync` working tree, NOT a clean upstream
  # snapshot. The 36 ollama patches and 8 Hal9000 SYCL patches are already
  # applied to the vendored llama.cpp under `ml/backend/ggml/ggml/src/`.
  # Patch *files* are kept under `llama/patches/` for reference but are
  # not re-applied at build time (mirrors how upstream nixpkgs ollama
  # treats its own tagged tarballs).
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

  # intel-llvm goes in buildInputs, not nativeBuildInputs. Its setup-hook
  # adds `-isystem $1/include` to NIX_CFLAGS_COMPILE only for host-role
  # (buildInputs); in nativeBuildInputs it would set
  # NIX_CFLAGS_COMPILE_FOR_BUILD which the host-targeted ggml-sycl
  # compile does not read, leaving `sycl/sycl.hpp` unresolvable.
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
  # cmd/launch test substitutions, `rm -r app`). The vendored source
  # already has SYCL wiring baked in (PR #16036's OLLAMA_ENABLE_SYCL
  # option + ggml-sycl install rules in CMakeLists.txt; bf16 IMF bypass
  # in set_rows.cpp; HOST_MEM_FALLBACK CMake option from Hal9000 patch
  # #8) — no splicing/preset/CMake-block injection needed at derivation
  # time. The only adjustments below are the device-side memcpy fixes
  # IGC needs and the upstream MMVQ unaligned-vocab patch.
  #
  # OllamaEngineRequired is left untouched — qwen35* now routes through
  # the new ollama-engine path (verified working at this base commit;
  # the original Feb-2026 graph_compute_async SIGSEGV is gone).
  postPatch = (oldAttrs.postPatch or "") + ''
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

    # ggml-sycl/convert.cpp gates the bf16 dequant path behind
    # `__INTEL_LLVM_COMPILER`, which is set only by Intel's proprietary
    # icpx/dpcpp. nixpkgs' open-source intel-llvm DPC++ exposes the same
    # `<sycl/ext/oneapi/bfloat16.hpp>` extension but identifies as plain
    # Clang. Without this patch, mixed-precision models (gpt-oss:20b is
    # MXFP4 weights + bf16 norms/embeds) abort on first decode with
    # `convert.cpp:764: fatal error: unsupport data type=bf16`. Patch
    # keeps only the `__has_include` check.
    patch -p4 -d ml/backend/ggml/ggml/src/ggml-sycl \
      < ${../llama-cpp-sycl/patches/0010-SYCL-Enable-BF16-convert-on-open-source-DPC.patch}
  '';

  # FORTIFY workaround: IGC has no `__memcpy_chk` symbol so SYCL kernel
  # JIT fails when ggml-sycl's dpct/helper.hpp `std::memcpy` gets the
  # FORTIFY-checked variant. Disabling via cc-wrapper hardening actually
  # removes the `-D_FORTIFY_SOURCE=2` injection, unlike CMake-level
  # `target_compile_options(... -D_FORTIFY_SOURCE=0)` which loses the
  # race against the wrapper.
  hardeningDisable = (oldAttrs.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];

  # Skip Go-side check phase: ollama's `integration/` package has all
  # build-tag-gated files which `go test ./...` reports as
  # `[setup failed]`. doInstallCheck still runs the version probe.
  doCheck = false;

  # intel-llvm's setup-hook is observed not to add the -isystem flag
  # under buildGoModule's cc-wrapper. Force it here (NOT via
  # `env.NIX_CFLAGS_COMPILE`, which would replace rather than append
  # and drop nixpkgs' standard flags like `-fdebug-prefix-map`).
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

  # SYCL runtime defaults for the ollama-sycl wrapper.
  #
  # SYCL_CACHE_PERSISTENT=0 is load-bearing: intel-llvm@unstable-2025-11-14's
  # libsycl.so.8 has a NULL-deref in sycl::detail::getSortedImages →
  # __insertion_sort comparator → strcmp on the in-memory
  # `vector<RTDeviceBinaryImage*>` it sorts inside
  # PersistentDeviceCodeCache::getItemFromDisc, called from
  # `getOrCreateURProgram` at first kernel JIT (verified via libunwind
  # backtrace 2026-05-08, full trace in project_ollama_sycl_fork.md).
  # Reproducer: any SYCL kernel JIT'd via the persistent-cache path
  # SIGSEGVs at first decode in the ollama runner. Setting
  # SYCL_CACHE_PERSISTENT=0 bypasses `getItemFromDisc` entirely.
  #
  # ZES_ENABLE_SYSMAN=1 — accurate VRAM free-memory queries on Battlemage.
  #
  # ONEAPI_DEVICE_SELECTOR=opencl:gpu — route through the SYCL OpenCL UR
  # adapter rather than the Level Zero UR adapter. ggml-sycl itself
  # works on L0 V2 on Battlemage (`llama-bench` via `pkg/llama-cpp-sycl`
  # measured 2.14× faster tg16 on L0 vs OpenCL), so the bug here is
  # NOT in ggml-sycl / libsycl / NEO at large. It is specific to the
  # ollama runner subprocess: when ollama-runner spawns the embedded
  # llama runner over the L0 backend, the child SIGSEGVs inside
  # libsycl before any SYCL backend log fires (Go runtime panic +
  # register dump from the parent, no stderr from the child).
  # Suspected cause: env-var propagation through ollama-runner's
  # exec model differs from a direct shell invocation; the L0 V2
  # adapter is sensitive to that. To be debugged separately. Until
  # then, force the runner onto OpenCL UR — same model, same kernels,
  # validated stable across architectures, ~50 % of L0's tg throughput
  # but functionally correct.
  #
  # OCL_ICD_VENDORS — point the bundled ocl-icd loader inside SYCL at
  # NixOS's OpenCL ICD directory so the Intel NEO ICD is discoverable.
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
    description = "Ollama with SYCL backend (Intel Arc / Battlemage / Xe2) — llama.cpp@073bb2c20";
  };
})

# ollama 0.21 with the GGML SYCL backend grafted in for the Intel Arc Pro B70
# (and any other Battlemage / Xe2 device).
#
# Why a derivation, not an upstream PR:
#   - ollama 0.21 vendors `ml/backend/ggml/ggml/src/` from upstream llama.cpp
#     but explicitly *excludes* `ggml-sycl/` via `.rsync-filter`.
#   - The CMake hook `ggml_add_backend(SYCL)` is present but no source
#     subdirectory exists — the SYCL backend cannot compile without one.
#   - The Go-side discoverer (`discover/runner.go`) already routes by
#     directory name (`vulkan`, `cuda_v12`, etc), so dropping a `sycl/`
#     dir under `lib/ollama/` is enough to make the runner pick it up
#     when `OLLAMA_LLM_LIBRARY=sycl` is set.
#
# Build strategy:
#   1. Inherit nixpkgs `ollama` (CPU variant, version 0.21.0).
#   2. In `postPatch`, splice the upstream ggml-sycl/ directory from the
#      *exact same* commit ollama already vendors (`ec98e2002`). Same
#      SHA the rest of the vendored ggml is cut from, so ABI/types match.
#   3. Patch the root CMakeLists.txt: add an `if(GGML_SYCL_BUILD)` block
#      that mirrors the existing Vulkan pattern — `add_subdirectory` +
#      `install(TARGETS ggml-sycl ...)` to `${OLLAMA_INSTALL_DIR}`.
#   4. Add a `SYCL` preset to CMakePresets.json setting
#      `OLLAMA_RUNNER_DIR=sycl` and `GGML_SYCL_BUILD=ON`.
#   5. Wire intel-llvm/mkl-sycl/intel-compute-runtime/level-zero/oneDNN
#      into nativeBuildInputs+buildInputs, set CC/CXX to intel-llvm's
#      clang via the same icx/icpx shim as `pkg/llama-cpp-sycl/`.
#   6. Wrap the `ollama` binary with the same OPENCL/SYCL env defaults
#      as `pkg/llama-cpp-sycl/` (ONEAPI_DEVICE_SELECTOR=opencl:gpu,
#      OCL_ICD_VENDORS, plus OLLAMA_LLM_LIBRARY=sycl so the runner picks
#      the SYCL backend without a manual override).
#
# Runtime requires the same NixOS module config `pkg/llama-cpp-sycl/`
# expects: `hardware.graphics.extraPackages` includes
# `intel-compute-runtime` and `intel-compute-runtime.drivers`. Already
# done in `modules/nixos/intel-gpu.nix`.
{
  lib,
  ollama,
  fetchFromGitHub,
  stdenv,
  intel-llvm,
  intel-compute-runtime,
  level-zero,
  ocl-icd,
  mkl-sycl,
  oneDNN,
  tbb,
  cmake,
  pkg-config,
  makeWrapper,
  perl,    # multi-line postPatch substitution (substituteInPlace can't)
}:

let
  # The upstream llama.cpp commit we surgically lift `ggml-sycl/` from.
  # ollama vendors ec98e2002 (Dec 2025) for the rest of ggml; we keep
  # that commit for ggml core/CPU/CUDA/Vulkan (so ollama's 36 patches
  # apply cleanly) but replace ONLY ggml-sycl/ with this newer commit.
  # Pattern lifted from eleiton/ollama-intel-arc which proved this
  # surgical-bump approach works in practice.
  #
  # Why bump just ggml-sycl: between ec98e2002 and recent master, the
  # SYCL backend got fixes we directly need:
  #   - b1be68e8ca [SYCL] Fix Q8_0 reorder: garbage on 2nd prompt + crash on full VRAM
  #   - 225088ea76 sycl: Improve mul_mat_id memory efficiency + BF16 fast path
  #     (replaces our manual IMF-bypass postPatch)
  #   - 60b68a6279 sycl: fused MoE mul_mat_vec_q for TG (qwen3.5moe etc)
  #   - 4ead6fd957 [SYCL] Update oneapi 2025.3.3
  #   - eddd7a13a5 [SYCL] Optimize Q4_0 mul_mat for Arc770
  #
  # eleiton's verified-safe pin (Jan 8 2026, +241 commits past
  # ec98e2002). Tried bumping to current master (May 4 2026) for the
  # targeted SYCL fixes (Q8_0 reorder, BF16 fast path, fused MoE
  # mul_mat_vec_q) but the ggml backend ABI itself was rewritten
  # between those dates — new callback signatures, new ops
  # (GGML_OP_GATED_DELTA_NET), new quant types (GGML_TYPE_Q1_0,
  # block_nvfp4), grown struct layouts. Backporting all those into
  # ollama's Dec-2025 ggml-base is a multi-evening project (the
  # original "vendor bump" we estimated). Stay at eleiton's pin until
  # either upstream ollama bumps its vendor or we commit to the full
  # bump. qwen3.5moe inference stays broken at this pin.
  ggmlSyclCommit = "15bff84bf56651d6f991f166a2bf0f362996f7f9";
  llamaCppSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = ggmlSyclCommit;
    hash = "sha256-sxkRgGdUFN0iKnjvogw+sxCe8g36LHh55FeX0kKwF/k=";
  };

in
ollama.overrideAttrs (oldAttrs: {
  pname = "ollama-sycl";

  # Inherits version + src + vendorHash from `ollama` — globals.nix's
  # overlay bumps the base nixpkgs `ollama` to 0.23.0, and overrideAttrs
  # carries that through to ollama-sycl unchanged. If you ever bump
  # ollama-sycl ahead of the rest, set version + src + vendorHash here.

  nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [
    cmake
    pkg-config
    makeWrapper
    perl
  ];

  # intel-llvm goes in *buildInputs*, not nativeBuildInputs. Its
  # setup-hook does
  #   export NIX_CFLAGS_COMPILE''${role_post}+=" -isystem $1/include"
  # — `role_post` is empty for buildInputs (host role) and
  # `_FOR_BUILD` for nativeBuildInputs (build role). Putting it in
  # nativeBuildInputs sets `NIX_CFLAGS_COMPILE_FOR_BUILD`, which the
  # host-targeted ggml-sycl compile does NOT read, so `sycl/sycl.hpp`
  # (which lives in intel-llvm's merged-output `/include/sycl/`) goes
  # missing. host-role buildInputs gets it onto NIX_CFLAGS_COMPILE,
  # which clang's cc-wrapper passes through.
  buildInputs = (oldAttrs.buildInputs or [ ]) ++ [
    intel-llvm
    intel-compute-runtime
    level-zero
    ocl-icd
    mkl-sycl
    oneDNN
    tbb
  ];

  # Splice the upstream ggml-sycl/ tree into the vendored ggml source,
  # then add the CMake hook (mirrors the Vulkan block in CMakeLists.txt).
  # Done in postPatch (after upstream's substituteInPlace+app-removal)
  # so we don't get reordered with their patches.
  postPatch = (oldAttrs.postPatch or "") + ''
    # 1. Splice ggml-sycl/ from upstream into the vendored ggml tree.
    cp -r ${llamaCppSrc}/ggml/src/ggml-sycl ml/backend/ggml/ggml/src/
    chmod -R u+w ml/backend/ggml/ggml/src/ggml-sycl

    # (NVFP4 backport not needed at eleiton's pin — that quant type
    # was added upstream after Jan 8. Leave this comment as a marker
    # of what to re-add if we ever bump past 5eae9cb1d9, 2026-03-11.)

    # 2. Mirror the Vulkan stanza in CMakeLists.txt for SYCL. Gated by
    #    the GGML_SYCL_BUILD option (off by default; the SYCL preset
    #    enables it).
    cat >> CMakeLists.txt <<'CMAKE_SYCL_EOF'

# Ollama-SYCL: Intel Arc / Battlemage support. Mirrors the Vulkan
# subdirectory pattern above — adds ggml-sycl as a separate shared
# library installed under ''${OLLAMA_INSTALL_DIR}, picked up by the
# runner when OLLAMA_LLM_LIBRARY=sycl.
option(GGML_SYCL_BUILD "Enable the GGML SYCL backend (Intel oneAPI / Level Zero)" OFF)
if(GGML_SYCL_BUILD AND NOT APPLE)
    set(GGML_SYCL ON)
    set(GGML_SYCL_TARGET INTEL)
    set(GGML_SYCL_F16 ON)
    # Workaround for llama.cpp issue #21893 — ggml-sycl graph-capture
    # path produces wrong results on B70.
    set(GGML_SYCL_GRAPH OFF)
    # MKL 2025.x's tbb_thread backend wants TBBConfig.cmake on the
    # CMake prefix path; nixpkgs' tbb.dev provides it but MKLConfig
    # bails before falling through. Use Intel OpenMP (libiomp5.so from
    # mkl-sycl) instead — safe for GPU SYCL where CPU threading mode
    # only matters for kernel launches.
    set(MKL_THREADING intel_thread)
    set(MKL_SYCL_THREADING intel_thread)

    add_subdirectory(''${CMAKE_CURRENT_SOURCE_DIR}/ml/backend/ggml/ggml/src/ggml-sycl)
    target_include_directories(ggml-sycl PRIVATE ''${GGML_INCLUDE_DIRS})

    # (See postPatch below — bf16 IMF bypass is patched into
    # ggml-sycl's set_rows.cpp at source level, since
    # intel-llvm@unstable-2025-11-14 has no `-fsycl-device-lib` flag
    # to opt into the IMF bf16 bitcode at link time.)

    install(TARGETS ggml-sycl
        RUNTIME_DEPENDENCIES
            PRE_INCLUDE_REGEXES "mkl_sycl|mkl_intel|mkl_core|mkl_tbb|mkl_def|libsycl|libOpenCL|libze|libiomp"
            PRE_EXCLUDE_REGEXES ".*"
        RUNTIME DESTINATION ''${OLLAMA_INSTALL_DIR} COMPONENT SYCL
        LIBRARY DESTINATION ''${OLLAMA_INSTALL_DIR} COMPONENT SYCL
    )
endif()
CMAKE_SYCL_EOF

    # 3. Add the SYCL preset via CMakeUserPresets.json — cmake reads
    #    both files and merges. Avoids surgery on the upstream
    #    CMakePresets.json (where the Vulkan entry appears twice — in
    #    configurePresets and buildPresets — and buildPresets schema
    #    rejects cacheVariables, so any string-replace approach blows
    #    up there). Use a Nix-side toJSON to dodge bash heredoc
    #    indentation gotchas (PRESETS_EOF can't be unindented inside an
    #    indented Nix string without ruining file alignment).
    cp ${builtins.toFile "CMakeUserPresets.json" (builtins.toJSON {
      version = 3;
      configurePresets = [{
        name = "SYCL";
        inherits = [ "Default" ];
        cacheVariables = {
          OLLAMA_RUNNER_DIR = "sycl";
          GGML_SYCL_BUILD = "ON";
        };
      }];
      buildPresets = [{
        name = "SYCL";
        configurePreset = "SYCL";
      }];
    })} CMakeUserPresets.json
    chmod u+w CMakeUserPresets.json

    # 4. ggml-sycl@ec98e2002 expects MKL::MKL_SYCL::BLAS namespaced
    #    target (oneMKL 2024.1+). Our mkl-sycl is 2025.3.1 — this
    #    target exists natively, no patch needed.

    # 5. Same _FORTIFY_SOURCE issue as pkg/llama-cpp-sycl/: IGC has no
    #    __memcpy_chk symbol. Handled by hardeningDisable below.

    # 6. ollama's vendored ggml carries patch
    #    `0018-ggml-Add-batch-size-hint.patch` which adds a third
    #    `int batch_size` argument to the backend `graph_compute`
    #    callback (and the public `ggml_backend_graph_compute_async`).
    #    ollama then re-patches ggml-cuda/vulkan/etc to match. Upstream
    #    ggml-sycl@ec98e2002 still uses the original 2-arg signature.
    #    Since we vendored that source verbatim, the type-init in
    #    ggml_backend_sycl_i hits a type mismatch. Bump the SYCL backend's
    #    signature to the patched ABI; the batch_size hint is unused
    #    inside ggml-sycl's compute path (kernels are dispatched per
    #    op, not per graph), so accepting and ignoring it is correct.
    substituteInPlace ml/backend/ggml/ggml/src/ggml-sycl/ggml-sycl.cpp \
      --replace-fail \
        'static ggml_status ggml_backend_sycl_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph) {' \
        'static ggml_status ggml_backend_sycl_graph_compute(ggml_backend_t backend, ggml_cgraph * cgraph, int /*batch_size*/) {'

    # 7a. Force standard-transformer Qwen3 family back onto the legacy
    #     llama.cpp runner. ollama 0.21+ routes any architecture in
    #     `fs/ggml/ggml.go:OllamaEngineRequired()` through the
    #     Go-native "ollama-engine" instead of the legacy runner —
    #     and the new engine has a SYCL-side bug that NULL-derefs in
    #     `ggml_backend_sched_graph_compute_async` on first prompt
    #     (silent SIGSEGV). Verified empirically: same architecture
    #     models load + serve correctly via llama-cli (which uses the
    #     same ggml-sycl shared lib), so the legacy ollama runner
    #     should work too. Strip just the classic-transformer arches
    #     (qwen3, qwen3moe, qwen35, qwen35moe); leave qwen3next,
    #     qwen3vl, qwen3vlmoe on the new engine since they need its
    #     Mamba-SSM / vision support that llama.cpp lacks anyway.
    #     Drop this patch when the ollama-engine SYCL dispatch bug
    #     is fixed upstream.
    # Strip ONLY `qwen3, qwen3moe` from OllamaEngineRequired — those
    # have full classic-transformer support in the legacy llama.cpp
    # runner (proven via llama-cli + ollama). Leave `qwen35, qwen35moe`
    # on the new-engine path because the legacy llama.cpp@ec98e2002
    # arch loader doesn't know `qwen35moe` and fails with
    # "unknown model architecture: 'qwen35moe'". The new engine has
    # its own Go-native arch handler that DOES know qwen35* and
    # dispatches to ggml-sycl — which we bumped above to a newer SYCL
    # source that includes Q8_0 reorder + bf16 fast-path + MoE
    # mul_mat_vec_q fixes that may resolve the original new-engine
    # SIGSEGV.
    #
    # If qwen35* still crashes after this bump, the next step is to
    # bump ggml-sycl further (master has 1000+ commits past 15bff84
    # with even more SYCL fixes) before considering Go-side patches.
    perl -i -0777 -pe '
      s{"qwen25vl",\n\t\t"qwen3", "qwen3moe",\n}
       {"qwen25vl",\n\t\t// "qwen3", "qwen3moe" — forced to legacy runner via ollama-sycl postPatch\n}s
    ' fs/ggml/ggml.go
    grep -q 'forced to legacy runner via ollama-sycl postPatch' fs/ggml/ggml.go \
      || (echo "qwen3 routing patch did not apply to fs/ggml/ggml.go"; exit 1)

    # 7b. bf16 conversion bypass for `set_rows` — see pkg/llama-cpp-sycl/
    #     for the full rationale. perl -0777 multi-line substitution
    #     (substituteInPlace can't reliably match across lines under
    #     Nix indented-string whitespace stripping).
    perl -i -0777 -pe '
      s{auto dst_val = sycl::vec<TIn, 1>\(src_val\)\.template convert<TOut, sycl::rounding_mode::automatic>\(\)\[0\];\n\s+\*reinterpret_cast<TOut\*>\(dst\) = dst_val;}
       {if constexpr (std::is_same_v<TOut, sycl::ext::oneapi::bfloat16>) {
        *reinterpret_cast<TOut*>(dst) = sycl::ext::oneapi::bfloat16(static_cast<float>(src_val));
    } else {
        auto dst_val = sycl::vec<TIn, 1>(src_val).template convert<TOut, sycl::rounding_mode::automatic>()[0];
        *reinterpret_cast<TOut*>(dst) = dst_val;
    }}s
    ' ml/backend/ggml/ggml/src/ggml-sycl/set_rows.cpp
    grep -q 'is_same_v<TOut, sycl::ext::oneapi::bfloat16>' ml/backend/ggml/ggml/src/ggml-sycl/set_rows.cpp \
      || (echo "bf16 IMF-bypass perl substitution did not apply to set_rows.cpp"; exit 1)
  '';

  hardeningDisable = (oldAttrs.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];

  # The upstream ollama Go test phase walks `./...` which includes the
  # `integration/` package — every file there has `//go:build
  # integration`, so without the tag `go test` reports "build
  # constraints exclude all Go files in /build/source/integration"
  # and counts that as `[setup failed]`. Upstream nixpkgs ollama somehow
  # tolerates this, but our override path fails on it. Skip Go-side
  # checks here — versionCheckHook (inherited via doInstallCheck) still
  # runs to verify the binary works.
  doCheck = false;

  # nixpkgs intel-llvm's wrapper-derivation has a setup-hook that *should*
  # add `-isystem ${intel-llvm}/include` to NIX_CFLAGS_COMPILE — but that
  # hook doesn't fire under buildGoModule's cc-wrapper (verified
  # empirically: only mkl-sycl's -isystem appears in the compile line).
  # ggml-sycl.cpp #include's <sycl/sycl.hpp> which lives under
  # ${intel-llvm}/include/sycl/. Force the include path explicitly via
  # preConfigure (NOT via `env.NIX_CFLAGS_COMPILE`, which would *replace*
  # rather than append — and dropping nixpkgs' standard flags also drops
  # `-fdebug-prefix-map`, leaving raw go-compiler store paths in DWARF
  # which trip disallowedReferences at install-time).
  preConfigure = (oldAttrs.preConfigure or "") + ''
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -isystem ${intel-llvm}/include"
  '';

  # Make MKLConfig.cmake's CMAKE_CURRENT_LIST_DIR/../.. lookups land at
  # the right prefix.
  MKLROOT = mkl-sycl;

  # MKLConfig detects the DPC++ compiler by basename — symlink
  # intel-llvm's clang/clang++ as icx/icpx so MKLConfig flips
  # DPCPP_COMPILER=ON. Same trick as pkg/llama-cpp-sycl/.
  preBuild = ''
    mkdir -p $TMPDIR/intel-shim/bin
    ln -sf ${intel-llvm}/bin/clang   $TMPDIR/intel-shim/bin/icx
    ln -sf ${intel-llvm}/bin/clang++ $TMPDIR/intel-shim/bin/icpx
    export CC=$TMPDIR/intel-shim/bin/icx
    export CXX=$TMPDIR/intel-shim/bin/icpx
    export PATH=$TMPDIR/intel-shim/bin:$PATH

    # Run the SYCL preset (sets OLLAMA_RUNNER_DIR=sycl,
    # GGML_SYCL_BUILD=ON). Mirrors upstream's preBuild structure.
    # CMAKE_VERBOSE_MAKEFILE=ON dumps the actual compile lines on
    # failure — crucial for debugging "include not found" classes of
    # error. Cheap to keep while ollama-sycl is fresh.
    cmake -B build \
        --preset SYCL \
        -DCMAKE_SKIP_BUILD_RPATH=ON \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -DCMAKE_VERBOSE_MAKEFILE=ON

    cmake --build build -j $NIX_BUILD_CORES
  '';

  # Wrap with SYCL runtime env defaults. Note: do *not* set
  # OLLAMA_LLM_LIBRARY=sycl — that env var skips libDirs whose
  # `filepath.Base(dir)` doesn't equal the requested name (see
  # discover/runner.go), and our libggml-sycl.so lands flat in
  # `lib/ollama/` (Base = "ollama"), exactly like libggml-vulkan.so in
  # nixpkgs ollama-vulkan. ggml's backend-reg auto-loads all
  # `libggml-*.so` from the library path on init, so SYCL is picked up
  # without explicit gating.
  #
  # ONEAPI_DEVICE_SELECTOR=opencl:gpu — intel-compute-runtime 26.09
  # GMM helper aborts during Level Zero init on B70 (revisit when ICR
  # bumps). OpenCL backend bypasses that path; ~5-10% slower, correct.
  # SYCL_CACHE_PERSISTENT — caches JIT'd kernels across runs
  # (multi-second cold-start otherwise).
  # ZES_ENABLE_SYSMAN — accurate VRAM free-memory queries on Battlemage.
  postFixup = (oldAttrs.postFixup or "") + ''
    if [ -e $out/bin/ollama ]; then
      wrapProgram $out/bin/ollama \
        --set-default ONEAPI_DEVICE_SELECTOR opencl:gpu \
        --set-default OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors \
        --set-default SYCL_CACHE_PERSISTENT 1 \
        --set-default ZES_ENABLE_SYSMAN 1
    fi
  '';

  meta = (oldAttrs.meta or { }) // {
    description = "Ollama with the Intel oneAPI SYCL backend (Arc / Battlemage / Xe2)";
  };
})

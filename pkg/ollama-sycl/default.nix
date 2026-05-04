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
}:

let
  # The exact upstream llama.cpp commit ollama 0.21 vendors. Matching
  # the SHA is non-negotiable — ggml's internal types/structs/headers
  # change frequently and a different commit produces silent ABI drift
  # against the rest of the already-vendored ggml backends.
  ggmlSyclCommit = "ec98e20021f7611db3bbcf6bb6629fed6e1ce4f0";
  llamaCppSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = ggmlSyclCommit;
    # Same hash as pkg/llama-cpp-sycl/default.nix — content-addressed,
    # nix dedupes the fetch.
    hash = "sha256-0O7dtGrIK7wG2DE4fEDcdWkAa5tdYnMJDBxCczgEZgs=";
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

    # Link the *full* SYCL device library set, not the default subset
    # (libc + libm-fp32). ggml-sycl's `set_rows_sycl<…, bfloat16>`
    # template instantiation calls `__imf_float2bfloat16_rn` from
    # Intel's IMF (Intel Math Function) bf16 library; without
    # `-fsycl-device-lib=all` the IMF bf16 fallback bitcode isn't
    # linked into the device image, so the kernel JIT fails at first
    # use with:
    #   error : unresolved external symbol __imf_float2bfloat16_rn
    #     ... aka kernel : set_rows_sycl<…, bfloat16> ...
    #   Exception caught at ggml-sycl.cpp:3957, Error OP SET_ROWS
    # which manifests on any model containing bf16 tensors (e.g.
    # qwen3.6, gemma3 27B bf16). Apply on both compile + link sides
    # because the device-library selection has to be visible to both.
    target_compile_options(ggml-sycl PRIVATE "-fsycl-device-lib=all")
    target_link_options(ggml-sycl PRIVATE "-fsycl-device-lib=all")

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

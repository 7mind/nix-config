# llama.cpp built with the SYCL backend, using nixpkgs `intel-llvm` as the
# DPC++ toolchain. Pinned to the exact upstream commit ollama 0.21.0 vendors
# (`ec98e20021f7611db3bbcf6bb6629fed6e1ce4f0`, 2025-12-16) so the
# `ggml-sycl/` directory we end up shipping in the ollama fork later is
# binary-compatible with the rest of ggml ollama already vendored.
#
# Build: nix build .?submodules=1#llama-cpp-sycl
# Run  : OCL_ICD_VENDORS=/run/opengl-driver/etc/OpenCL/vendors \
#        result/bin/llama-cli --list-devices
#
# Note: this is a smoke-test / staging package. Once the ollama fork is
# integrated and proven, this can either stay as a useful side artifact
# (llama-server is a clean OpenAI-compatible endpoint) or be retired.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  makeWrapper,
  intel-llvm,
  intel-compute-runtime,
  level-zero,
  ocl-icd,
  curl,
  mkl,        # Intel Math Kernel Library — ggml-sycl hard-requires it for BLAS
  oneDNN,     # Intel Deep Neural Network Library — soft optional, used if present
  tbb,        # Threading Building Blocks — MKL's default threading backend
}:

# Use the plain stdenv (not intel-llvm.stdenv): intel-llvm's stdenv
# passthru is built via `overrideCC baseLlvm.stdenv self.merged`, where
# self.merged refers to the package-internal merged derivation. Our
# overlay-level overrideAttrs (in globals.nix) fixes that merged output
# but doesn't propagate back into the scope, so intel-llvm.stdenv keeps
# the broken-empty CC. Working around by depending on intel-llvm as a
# nativeBuildInput and pointing CC/CXX at it explicitly in preConfigure.
stdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-sycl";
  version = "ec98e2002";

  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "ec98e20021f7611db3bbcf6bb6629fed6e1ce4f0";
    hash = "sha256-0O7dtGrIK7wG2DE4fEDcdWkAa5tdYnMJDBxCczgEZgs=";
  };

  # intel-llvm in nativeBuildInputs so its bin/clang(++) is on $PATH and
  # the (now-fixed) merged output is in the build closure.
  nativeBuildInputs = [ cmake pkg-config makeWrapper intel-llvm ];

  # Override CC/CXX explicitly. Two layers here:
  # 1. nixpkgs cmake setup-hook reads $CC/$CXX and passes them as
  #    -DCMAKE_{C,CXX}_COMPILER. Without this, the empty values from
  #    the regular gcc stdenv get passed (and don't link against
  #    intel-llvm's libsycl.so).
  # 2. MKL 2023.1's MKLConfig.cmake detects the DPC++ compiler by the
  #    *basename* of CMAKE_CXX_COMPILER — only "icpx", "dpcpp", "icx"
  #    enable DPCPP_COMPILER=ON, which is the gate for the
  #    `MKL::mkl_sycl` target ggml-sycl needs. intel-llvm's binary is
  #    just `clang++`, so MKL leaves DPC++ off. Workaround: symlink the
  #    clang/clang++ as icx/icpx in $TMPDIR and point CC/CXX there.
  preConfigure = ''
    mkdir -p $TMPDIR/intel-shim/bin
    ln -s ${intel-llvm}/bin/clang   $TMPDIR/intel-shim/bin/icx
    ln -s ${intel-llvm}/bin/clang++ $TMPDIR/intel-shim/bin/icpx
    export CC=$TMPDIR/intel-shim/bin/icx
    export CXX=$TMPDIR/intel-shim/bin/icpx
    export PATH=$TMPDIR/intel-shim/bin:$PATH
  '';

  # bf16 conversion bypass for `set_rows`. Upstream uses
  #   sycl::vec<TIn, 1>(src_val).convert<bfloat16, automatic>()
  # which intel-llvm lowers to `__imf_float2bfloat16_rn` from the
  # IMF (Intel Math Function) bitcode library — and that bitcode is
  # NOT auto-linked by intel-llvm@unstable-2025-11-14 (the snapshot
  # has no `-fsycl-device-lib` driver flag at all, verified via
  # `clang++ --help-hidden`). On any model with bf16 tensors
  # (qwen3.6, gemma3-bf16) the device JIT fails at first dispatch:
  #   error : unresolved external symbol __imf_float2bfloat16_rn
  #     ... aka kernel : set_rows_sycl<…, bfloat16> ...
  #   Exception caught at ggml-sycl.cpp:NNNN, Error OP SET_ROWS
  # Specialize on bfloat16 to use the standard
  # `sycl::ext::oneapi::bfloat16(float)` constructor — IGC has native
  # SPIR-V intrinsics for that path that don't need IMF bitcode.
  postPatch = ''
    substituteInPlace ggml/src/ggml-sycl/set_rows.cpp \
      --replace-fail \
        'auto dst_val = sycl::vec<TIn, 1>(src_val).template convert<TOut, sycl::rounding_mode::automatic>()[0];
   *reinterpret_cast<TOut*>(dst) = dst_val;' \
        'if constexpr (std::is_same_v<TOut, sycl::ext::oneapi::bfloat16>) {
        *reinterpret_cast<TOut*>(dst) = sycl::ext::oneapi::bfloat16(static_cast<float>(src_val));
    } else {
        auto dst_val = sycl::vec<TIn, 1>(src_val).template convert<TOut, sycl::rounding_mode::automatic>()[0];
        *reinterpret_cast<TOut*>(dst) = dst_val;
    }'
  '';

  # MKLConfig.cmake locates everything relative to MKLROOT. Our
  # `mkl-sycl` derivation flattens lib/include into $out, so MKLROOT is
  # just the package out path. (Required because the cmake config's
  # `_root_climb_helper` symlink can't replace explicit MKLROOT for all
  # internal find_path() calls.)
  MKLROOT = mkl;

  # Runtime closure needs:
  #  - level-zero        : libze_loader.so (Level Zero ICD loader, linked at runtime)
  #  - intel-compute-runtime : the actual NEO L0 driver that registers with the loader
  #  - ocl-icd           : OpenCL fallback path; some ggml-sycl helpers use it for
  #                        device probing even when the actual workload runs on L0
  #  - curl              : llama.cpp's optional HTTP client for model downloads
  buildInputs = [
    intel-compute-runtime
    level-zero
    ocl-icd
    curl
    mkl
    oneDNN
    tbb
  ];

  cmakeFlags = [
    # MKLConfig.cmake's default `tbb_thread` does `find_package(TBB CONFIG)`
    # which expects an upstream-style TBBConfig.cmake at MKLROOT or on
    # CMAKE_PREFIX_PATH. nixpkgs `tbb` ships its TBBConfig in the `dev`
    # output, but MKLConfig still rejects it (suspected: MKLConfig
    # searches relative to MKLROOT first and bails before falling
    # through to the broader prefix path). Side-step by routing MKL's
    # CPU dispatch through Intel OpenMP (`libiomp5.so`, which we DO ship
    # in mkl-sycl/lib). For GPU SYCL workloads the CPU thread backend
    # only matters for kernel launches and small auxiliary ops, so this
    # has no measurable impact on inference throughput.
    (lib.cmakeFeature "MKL_THREADING"      "intel_thread")
    (lib.cmakeFeature "MKL_SYCL_THREADING" "intel_thread")

    # Core SYCL backend
    (lib.cmakeBool "GGML_SYCL"          true)
    # Targeting Intel GPUs specifically — also valid: NVIDIA, AMD, ALL
    (lib.cmakeFeature "GGML_SYCL_TARGET" "INTEL")
    # FP16 matmul kernels — Battlemage supports it; without this you fall
    # back to fp32 paths and lose ~2× throughput.
    (lib.cmakeBool "GGML_SYCL_F16"      true)
    # Use ggml-sycl's graph capture path — currently triggers a known
    # correctness bug on B70 (llama.cpp issue #21893). Disable for now;
    # revisit once upstream merges a fix.
    (lib.cmakeBool "GGML_SYCL_GRAPH"    false)

    # Tame defaults
    (lib.cmakeBool "BUILD_SHARED_LIBS"  false)  # static link — avoids RPATH games
    (lib.cmakeBool "LLAMA_BUILD_TESTS"  false)
    (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" true) # llama-cli, llama-server, llama-bench
    (lib.cmakeBool "LLAMA_CURL"         true)
  ];

  # ggml-sycl needs C++17, which intel-llvm's clang defaults to. Some upstream
  # warnings get promoted to errors with -Wall in newer Clang; loosen if so.
  env.NIX_CFLAGS_COMPILE = lib.concatStringsSep " " [
    "-Wno-error=deprecated-declarations"
    # intel/llvm's Clang ships a libc++ that conflicts with libstdc++'s
    # `isgreater` macro on math.h includes inside ggml-sycl
    # (llama.cpp #14440). Force libc++ via the SYCL stdenv if needed.
  ];

  # nixpkgs' default `_FORTIFY_SOURCE=2/3` makes Clang emit `__memcpy_chk`
  # (the bounds-checked memcpy) instead of plain `__memcpy`. The Intel
  # Graphics Compiler (IGC) shipping in `intel-compute-runtime` does not
  # implement `__memcpy_chk` in its device-side runtime, so the JIT step
  # fails at first kernel dispatch with:
  #
  #   error : unresolved external symbol __memcpy_chk at offset 500
  #     in instructions segment #3 (aka kernel : ... mul_mat_vec_mxfp4_q8_1_sycl ...)
  #
  # Disable fortify to fall back to the unchecked `__memcpy`. Same fix
  # the upstream `intel-compute-runtime` derivation already applies for
  # the host-side compile (see pkgs/.../intel-compute-runtime/package.nix
  # `hardeningDisable = ["fortify3"]`); we need it on the SYCL device
  # side too because IGC inherits NIX_CFLAGS_COMPILE for the kernels.
  hardeningDisable = [ "fortify" "fortify3" ];

  # Wrap binaries so users don't have to discover the right env vars.
  #
  # ONEAPI_DEVICE_SELECTOR=opencl:gpu — explicit reasoning: we'd prefer
  # `level_zero:gpu` (~5-10% faster + lower dispatch overhead), but the
  # nixpkgs Level Zero stack on Battlemage has two stacked bugs as of
  # 2026-05: (1) `intel-compute-runtime`'s `drivers` output had to be
  # added to hardware.graphics.extraPackages just to get
  # libze_intel_gpu.so on the loader's path (fix shipped in our
  # modules/nixos/intel-gpu.nix), and (2) even with the driver present,
  # intel-compute-runtime 26.09.37435.1 aborts in its GMM helper
  # during L0 init on the B70 (UNRECOVERABLE_IF in
  # gmm_helper/resource_info.cpp:15). OpenCL avoids the GMM init path
  # entirely and works flawlessly. Override at runtime via the env var
  # if you want to test L0 once those upstream bugs are fixed.
  #
  # OCL_ICD_VENDORS=/run/opengl-driver/etc/OpenCL/vendors — points the
  # bundled ocl-icd loader at NixOS's OpenGL/OpenCL driver farm, which
  # is where intel-compute-runtime's intel-neo.icd lands via
  # hardware.graphics.extraPackages.
  postFixup = ''
    for prog in llama-cli llama-server llama-bench; do
      if [ -e $out/bin/$prog ]; then
        wrapProgram $out/bin/$prog \
          --set-default ONEAPI_DEVICE_SELECTOR opencl:gpu \
          --set-default OCL_ICD_VENDORS /run/opengl-driver/etc/OpenCL/vendors
      fi
    done
  '';

  # llama.cpp's CMake install puts binaries in $out/bin/ already; nothing to do.
  meta = with lib; {
    description = "llama.cpp built with the SYCL backend (Intel Arc / Battlemage)";
    homepage    = "https://github.com/ggml-org/llama.cpp";
    license     = licenses.mit;
    platforms   = platforms.linux;
    mainProgram = "llama-cli";
  };
})

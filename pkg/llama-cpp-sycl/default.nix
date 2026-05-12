# llama.cpp built with the SYCL backend, using nixpkgs `intel-llvm` as the
# DPC++ toolchain.
#
# Pinned to llama.cpp `073bb2c20b5b2c919469653214aaa1a9895816a2` (2026-04).
# Same base used by:
#   - Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes — provides the 8
#     SYCL cherry-picks in `patches/0001-0008` (BF16 GET_ROWS, MoE
#     mul_mat_vec_q fusion, K-quant subgroup-16 DMMV, oneMKL small-matmul
#     route, reorder-OOM safety, RAII temp buffer + HOST_MEM_FALLBACK,
#     Q8_0 reorder dequantize). Without these, stock SYCL hangs on MoE
#     and crashes on Q8_0 on B70 (BMG-G31).
#   - `pkg/ollama-sycl/` — vendors the SAME commit (whole-tree) so both
#     binaries share kernel fixes. `patches/0009` (upstream PR #22035)
#     is the single source of truth for the MMVQ unaligned-vocab fix
#     and is referenced by relative path from ollama-sycl's postPatch.
#
# Roles:
#   - `llama-cli` / `llama-bench` — diagnostic/benchmark binaries
#   - `llama-server` — OpenAI-compatible endpoint, wired as a NixOS
#     systemd service via `modules/nixos/llama-server.nix`
#
# Build: nix build .?submodules=1#nixosConfigurations.vm.pkgs.llama-cpp-sycl
# Run  : OCL_ICD_VENDORS=/run/opengl-driver/etc/OpenCL/vendors \
#        result/bin/llama-cli --list-devices
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
  perl,       # multi-line postPatch substitution (substituteInPlace can't)
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
  version = "073bb2c20";

  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "073bb2c20b5b2c919469653214aaa1a9895816a2";
    hash = "sha256-zr6FVsmL96dnvxVuR+EaFwA0Xde9fC/Jdx76FTU2sCE=";
  };

  # Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes cherry-picks,
  # 8 SYCL-backend patches against this exact base. Apply order is
  # significant — see the README in that repo for the rationale.
  # We deliberately skip the kit's two Vulkan patches and the
  # in-progress fattn-tla skeleton; this build is SYCL-only.
  patches = [
    ./patches/0001-SYCL-Add-BF16-support-to-GET_ROWS-operation.patch
    ./patches/0002-sycl-fused-MoE-mul_mat_vec_q-for-TG.patch
    ./patches/0003-SYCL-use-native-subgroup-size-for-K-quant-DMMV-kerne.patch
    ./patches/0004-sycl-route-small-f32-matmuls-to-oneMKL-bypass-oneDNN.patch
    ./patches/0005-SYCL-fix-reorder-crash-when-device-memory-is-full.patch
    ./patches/0006-SYCL-add-RAII-temp-buffer-class-macro-guard-for-host.patch
    ./patches/0007-SYCL-Fix-Q8_0-reorder-add-missing-dequantize-path-fo.patch
    ./patches/0008-SYCL-document-GGML_SYCL_HOST_MEM_FALLBACK-build-opti.patch
    # Upstream PR #22035 / commit 788fcbc5 (Apr 2026, post-073bb2c20 base):
    # the four reorder_mul_mat_vec_q* SYCL dispatchers (Q4_0, Q8_0, Q4_K,
    # Q6_K) asserted `block_num_y % 16 == 0`, which fails for any model
    # whose output projection has nrows (= vocab size, since GGML_SYCL_MMV_Y=1)
    # not divisible by 16. Granite 3.0 (vocab 49155, 49155 % 16 = 3) and
    # HY-MT (120818) abort on first decode. The fix pads block_num_y up to
    # a subgroup multiple and relies on the kernel's existing
    # `if (row >= nrows) return;` guard. Tested upstream on B70 hardware.
    ./patches/0009-SYCL-Fix-reorder-MMVQ-assert-on-unaligned-vocab-size.patch
  ];

  # intel-llvm in nativeBuildInputs so its bin/clang(++) is on $PATH and
  # the (now-fixed) merged output is in the build closure.
  nativeBuildInputs = [ cmake pkg-config makeWrapper intel-llvm perl ];

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
  #
  # Note: this patches the WRITE path (set_rows.cpp); Hal9000's
  # patch #1 (`Add BF16 support to GET_ROWS operation`) covers the
  # READ path (getrows.cpp / ggml-sycl.cpp). Both are needed for full
  # bf16 model support — different ops, different files.
  #
  # perl -0777 (slurp mode) handles the multi-line pattern cleanly;
  # `substituteInPlace` would need exact-byte indentation and Nix
  # indented-string whitespace stripping makes that fragile.
  postPatch = ''
    perl -i -0777 -pe '
      s{auto dst_val = sycl::vec<TIn, 1>\(src_val\)\.template convert<TOut, sycl::rounding_mode::automatic>\(\)\[0\];\n\s+\*reinterpret_cast<TOut\*>\(dst\) = dst_val;}
       {if constexpr (std::is_same_v<TOut, sycl::ext::oneapi::bfloat16>) {
        *reinterpret_cast<TOut*>(dst) = sycl::ext::oneapi::bfloat16(static_cast<float>(src_val));
    } else {
        auto dst_val = sycl::vec<TIn, 1>(src_val).template convert<TOut, sycl::rounding_mode::automatic>()[0];
        *reinterpret_cast<TOut*>(dst) = dst_val;
    }}s
    ' ggml/src/ggml-sycl/set_rows.cpp
    grep -q 'is_same_v<TOut, sycl::ext::oneapi::bfloat16>' ggml/src/ggml-sycl/set_rows.cpp \
      || (echo "bf16 IMF-bypass perl substitution did not apply to set_rows.cpp"; exit 1)
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
    # revisit once upstream merges a fix. (Hal9000's kit enables it on
    # 073bb2c20; their patches may have side-effected the bug, but we
    # keep it OFF until we verify a regression-free run on B70.)
    (lib.cmakeBool "GGML_SYCL_GRAPH"    false)

    # oneDNN — Hal9000's kit enables it. Patch #4 routes small f32
    # matmuls to oneMKL *bypassing* oneDNN, so DNN is still used for
    # the larger paths. Without this flag the patch's branch is dead
    # code and we lose Gemma 4 / Qwen3 attention QKV speedups.
    (lib.cmakeBool "GGML_SYCL_DNN"      true)

    # Host-memory fallback — gated by patch #6 (RAII temp buffer +
    # macro guard). When VRAM is tight (loading ~30 GB models on the
    # 32 GB B70), the SYCL allocator falls back to pinned host memory
    # instead of returning OOM. Documented by patch #8.
    (lib.cmakeBool "GGML_SYCL_HOST_MEM_FALLBACK" true)

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

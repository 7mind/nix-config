# ollama-sycl: ollama with the GGML SYCL backend for the Intel Arc Pro B70
# (Battlemage / Xe2).
#
# Architecture (rewritten for ollama ≥ 0.30): ride the *clean* nixpkgs
# CPU-only Ollama build and plant `pkg/llama-cpp-sycl`'s prebuilt
# `libggml-sycl.so` alongside its llama-server. llama-server loads the
# module through GGML_BACKEND_DL without inheriting the host's CUDA or
# ROCm build selection.
#
# Ollama and llama-cpp-sycl build from the same ggml source pin.
# Both use the same ggml-base ABI (`libggml-base.so.1` as of b12651).
#
# This retires the previous whole-tree-vendor model (./ollama-src, 44
# patches, OLLAMA_ENABLE_SYCL preBuild): ollama 0.30 moved llama.cpp to
# CMake FetchContent + llama/compat/apply-patch.cmake, which is
# incompatible with a hand-vendored old-layout tree. All SYCL kernel
# fixes now live once in pkg/llama-cpp-sycl (and are all upstream as of
# b9509 except the intel-llvm IGC/IMF workarounds).
#
# Validated on the B70 — see pkg/llama-cpp-sycl for the build+run harness.
{
  lib,
  ollama,
  llama-cpp-sycl,
  makeWrapper,
}:

ollama.overrideAttrs (oldAttrs: {
  pname = "ollama-sycl";
  # Version inherited from the CPU-only Ollama build.

  nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ makeWrapper ];

  # Drop the SYCL ggml backend next to ollama's own libggml-*.so. It is
  # already fully RPATH'd (mkl-sycl, intel-llvm libsycl.so.9, level-zero,
  # intel-compute-runtime, oneDNN, tbb + autoAddDriverRunpath for
  # /run/opengl-driver/lib) by the llama-cpp-sycl build, so it is
  # self-contained — no extra LD_LIBRARY_PATH needed for the backend.
  postInstall = (oldAttrs.postInstall or "") + ''
    install -Dm555 ${llama-cpp-sycl}/bin/libggml-sycl.so $out/lib/ollama/libggml-sycl.so
  '';

  # SYCL runtime defaults for the wrapper:
  #
  # SYCL_CACHE_PERSISTENT=0 is load-bearing: intel-llvm@2025-11-14's
  # libsycl.so.8 has a NULL-deref in the persistent-device-code-cache
  # path (getItemFromDisc → getSortedImages comparator) at first kernel
  # JIT. Setting it 0 bypasses that path. ZES_ENABLE_SYSMAN=1 gives
  # accurate VRAM free-memory queries on Battlemage.
  #
  # No ONEAPI_DEVICE_SELECTOR default — SYCL auto-selects the Level Zero
  # UR adapter, the fastest path on Battlemage. Override at runtime with
  # ONEAPI_DEVICE_SELECTOR=opencl:gpu if needed.
  postFixup = (oldAttrs.postFixup or "") + ''
    wrapProgram $out/bin/ollama \
      --set-default SYCL_CACHE_PERSISTENT 0 \
      --set-default ZES_ENABLE_SYSMAN 1
  '';

  meta = (oldAttrs.meta or { }) // {
    description = "Ollama with SYCL backend (Intel Arc / Battlemage / Xe2) — llama.cpp@${llama-cpp-sycl.version}";
  };
})

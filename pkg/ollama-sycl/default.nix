# ollama-sycl: ollama with the GGML SYCL backend for the Intel Arc Pro B70
# (Battlemage / Xe2).
#
# Architecture (rewritten for ollama ≥ 0.30): ride the *clean* nixpkgs
# `ollama` (0.30.7) and PLANT `pkg/llama-cpp-sycl`'s prebuilt
# `libggml-sycl.so` into ollama's backend dir. ollama's Go engine loads
# ggml backends via GGML_BACKEND_DL — it globs `libggml-*.so` out of
# `lib/ollama/` and registers whatever it finds (this is exactly how the
# stock cuda/rocm/vulkan flavors ship their `libggml-{cuda,hip,vulkan}.so`).
#
# Why planting is ABI-safe here: nixpkgs ollama 0.30.7 vendors its
# Go-engine ggml at the SAME release as llama.cpp b9509 — both produce
# `libggml-base.so.0.13.1` (GGML_BACKEND_API_VERSION 2), and our
# `libggml-sycl.so` NEEDs `libggml-base.so.0`, which ollama provides
# unchanged. b9509 is also the exact commit ollama 0.30.7 pins for its
# llama-server FetchContent, so the whole stack is one ggml version.
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
  # version inherited from nixpkgs ollama (0.30.7).

  nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ makeWrapper ];

  # Drop the SYCL ggml backend next to ollama's own libggml-*.so. It is
  # already fully RPATH'd (mkl-sycl, intel-llvm libsycl.so.8, level-zero,
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
    description = "Ollama with SYCL backend (Intel Arc / Battlemage / Xe2) — llama.cpp@b9509";
  };
})

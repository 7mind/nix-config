{
  lib,
  stdenvNoCC,
  gcc,
}:

# LD_PRELOAD shim that overrides `sycl::platform::get_backend() const` to
# always return `sycl::backend::ext_oneapi_level_zero` (== 2).
#
# Why it exists
# -------------
# PyTorch's `c10::xpu::initGlobalDevicePoolState` (see XPUFunctions.cpp:113)
# filters SYCL platforms with a hardcoded equality check:
#
#     if (platform.get_backend() != sycl::backend::ext_oneapi_level_zero)
#         return false;  // skip this platform
#
# That filter rejects OpenCL-backed SYCL platforms even though the rest of
# PyTorch's XPU stack (oneDNN's `device_id` / `get_device_uuid` etc.)
# correctly handles OpenCL via its own backend switch. On the Intel Arc Pro
# B70 (Battlemage / xe-kmd) the Level-Zero NEO path aborts during driver
# init (`gmm_helper/resource_info.cpp:15` — upstream `intel/compute-runtime`
# issue #922, unfixed at time of writing); routing SYCL through the OpenCL
# UR adapter is the only working backend on this host today.
#
# Combined with `ONEAPI_DEVICE_SELECTOR=opencl:gpu` (so SYCL only loads the
# OpenCL UR adapter, never touches the broken NEO L0 path) and
# `OCL_ICD_VENDORS=/run/opengl-driver/etc/OpenCL/vendors` (so the OpenCL
# loader inside the SYCL runtime finds NixOS's Intel ICD), this shim is
# enough to make `torch.xpu.device_count() > 0` on Battlemage. Validated
# end-to-end with: fp32/fp16 matmul (3.7/3.2 TFLOPS @ 2048²), conv2d,
# nn.Linear training (gradients flow), SDPA on SD-UNet shapes, and
# transformer-block fwd+bwd.
#
# We *only* override `platform::get_backend` — not `device::get_backend`,
# `context::get_backend`, or `queue::get_backend`. Overriding the device-
# level query also tricks oneDNN's `get_device_uuid` into taking its
# L0-interop path on an OpenCL native handle and segfaulting in NEO's
# `Device::getHardwareInfo`. Keep this surgical.
#
# Built with `-nostdlib` so the .so depends only on the dynamic linker —
# avoids glibc-version conflicts when LD_PRELOAD'd into Python envs that
# pin an older nixpkgs (comfyui-nix's c0b0e0fd vs current).

stdenvNoCC.mkDerivation {
  pname = "sycl-force-platform-l0";
  version = "1";

  src = builtins.toFile "sycl_force_platform_l0.cpp" ''
    // sycl::backend enum value 2 == ext_oneapi_level_zero.
    extern "C" int _ZNK4sycl3_V18platform11get_backendEv(void *) { return 2; }
  '';

  unpackPhase = ":";
  dontConfigure = true;

  nativeBuildInputs = [ gcc ];

  buildPhase = ''
    runHook preBuild
    g++ -nostdlib -O2 -fPIC -shared "$src" -o libsycl_force_platform_l0.so
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0644 libsycl_force_platform_l0.so \
      "$out/lib/libsycl_force_platform_l0.so"
    runHook postInstall
  '';

  meta = {
    description = "LD_PRELOAD shim forcing sycl::platform::get_backend() to ext_oneapi_level_zero (PyTorch XPU on B70 via OpenCL UR)";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}

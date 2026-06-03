# onnxruntime-openvino — Intel's prebuilt PyPI wheel, repackaged so that
# `python3.pkgs.onnxruntime` reports `OpenVINOExecutionProvider` as available.
#
# Why a wheel and not a from-source build?
#   nixpkgs ships:
#     - onnxruntime 1.24.4 with NO `openvino` build flag at all (the
#       cmakeFlags only know cuda/rocm/nccl).
#     - openvino 2026.1.0.
#   Upstream onnxruntime 1.24.x's CMake hard-floors OpenVINO at 2025.0
#   and is officially tested against 2025.4.1 ("three latest releases of
#   OpenVINO"). 2026.1 is outside that window — the SONAME bump from
#   `libopenvino_onnx_frontend.so.2500` → `.2600` is exactly what burned
#   the abandoned nixpkgs PR #380543. The from-source path would need a
#   pinned `openvino_2025_4` carried alongside `pkgs.openvino` and a
#   patch series that is currently stalled in PR #457745.
#
#   Intel publishes `onnxruntime-openvino` on PyPI with the full
#   onnxruntime + the version-matched OpenVINO `.so` files bundled inside
#   the wheel — same binary that Immich's official `prod-openvino`
#   Dockerfile installs. By taking the wheel we sidestep the version-skew
#   problem entirely, at the cost of the closure carrying its own copy
#   of the OV runtime instead of sharing nixpkgs `pkgs.openvino`.
#
# Wheel selection:
#   - 1.24.1 is the latest PyPI release (uploaded 2026-02-26).
#   - We pick the cp313 wheel because the pinned nixpkgs default
#     `pkgs.python3` is 3.13. If the python default ever bumps, swap the
#     `wheels` entry below — the cp311/cp312 SHAs are kept commented for
#     quick switching.
#
# Runtime requirements (provided by hardware.graphics.extraPackages on
# the consuming host/container — see private/hosts/vm/containers/immich.nix):
#   - intel-compute-runtime + .drivers : libze_intel_gpu.so, libigc, NEO
#   - level-zero                       : libze_loader.so.1
#   - ocl-icd                          : libOpenCL.so.1
#   The wheel's bundled .so files dlopen these via SONAME, so we link
#   them via `addDriverRunpath` so /run/opengl-driver/lib lands on
#   their RUNPATH — same mechanism nixpkgs uses for any GPU userspace.
{
  lib,
  stdenv,
  fetchurl,
  buildPythonPackage,
  pythonOlder,
  autoPatchelfHook,
  addDriverRunpath,

  # Bundled-in-wheel native deps that autoPatchelfHook resolves directly.
  intel-compute-runtime,
  level-zero,
  ocl-icd,
  zlib,

  # Python deps — same set as stock python3Packages.onnxruntime.
  coloredlogs,
  numpy,
  packaging,
}:

let
  version = "1.24.1";

  # PyPI wheels are content-addressed: the prefix path is not derivable
  # from pname/version. Re-fetch from `pypi.org/pypi/onnxruntime-openvino/json`
  # if you bump the version.
  wheels = {
    "313" = {
      url = "https://files.pythonhosted.org/packages/08/07/f225999919f56506b603aaa3ff837ad563ab26f86906ed7fa7e5abcd849e/onnxruntime_openvino-${version}-cp313-cp313-manylinux_2_28_x86_64.whl";
      hash = "sha256-LDu3PmisJ/SJGvillcH69XTsaLdy5lg8kKC5l6GCJ4I=";
    };
    # Kept for quick switching if pkgs.python3 default moves:
    # "312" hash = "sha256-1hf6wvWaarXqWaeIw+FZIkChKWQlGarqp3R2Hf41FQ4=";
    # "311" hash = "sha256-MAfIA2NMxpxtUq8d6nznKdm7YrmhEHD9L5WRGRmQB6g=";
  };
in

buildPythonPackage {
  pname = "onnxruntime-openvino";
  inherit version;
  format = "wheel";

  # cp313 ABI lock. The wheel only ships cp311/cp312/cp313 manylinux_2_28
  # x86_64 — no aarch64, no macOS, no other CPython versions. Fail the
  # build loudly rather than silently fall back to the CPU-only stock
  # onnxruntime (which would then claim providers without OpenVINO).
  disabled = pythonOlder "3.13";

  src = fetchurl wheels."313";

  nativeBuildInputs = [
    autoPatchelfHook
    addDriverRunpath
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    zlib                  # libz.so.1 — needed by libonnxruntime.so + the providers + pybind11 .so
    intel-compute-runtime
    level-zero
    ocl-icd
  ];

  # Stock python3Packages.onnxruntime strips these three: they're dragged
  # in by onnxruntime's wheel METADATA but not actually required at
  # import time, and pulling them inflates the closure (sympy alone is
  # ~100 MB). The OpenVINO wheel inherits the same metadata, so the same
  # strips apply.
  pythonRemoveDeps = [
    "flatbuffers"
    "protobuf"
    "sympy"
  ];

  dependencies = [
    coloredlogs
    numpy
    packaging
  ];

  # The default `pythonRuntimeDepsCheckHook` (now appended automatically by
  # buildPythonPackage) resolves each consumer's `Requires-Dist: onnxruntime`
  # through `importlib.metadata.distribution("onnxruntime")`, which matches the
  # installed `.dist-info` directory name. This PyPI wheel installs as the
  # distribution `onnxruntime-openvino`, so any consumer that lists plain
  # `onnxruntime` as a *base* dependency (insightface, rapidocr) fails the
  # check with "onnxruntime not installed". Re-label the dist-info as
  # `onnxruntime` so this wheel is a complete drop-in replacement at the
  # distribution-metadata level, not only at the `import onnxruntime` level.
  # (immich-machine-learning lists onnxruntime only under extras — markers the
  # hook skips — so it is unaffected either way.)
  postInstall = ''
    distInfo=$(echo "$out"/lib/python*/site-packages/onnxruntime_openvino-${version}.dist-info)
    mv "$distInfo" "''${distInfo/onnxruntime_openvino-/onnxruntime-}"
    substituteInPlace \
      "$out"/lib/python*/site-packages/onnxruntime-${version}.dist-info/METADATA \
      --replace-fail "Name: onnxruntime-openvino" "Name: onnxruntime"
  '';

  # Append /run/opengl-driver/lib (host's GPU userspace) to the RUNPATH
  # of every bundled .so, so dlopen("libze_loader.so.1") at runtime
  # resolves against the live driver stack — same trick nixpkgs uses
  # for ollama-cuda, blender, mesa-demos, etc.
  postFixup = ''
    find $out -name '*.so' -o -name '*.so.*' | while read so; do
      addDriverRunpath "$so"
    done
  '';

  # Importing `onnxruntime` triggers eager loading of the OpenVINO EP
  # provider .so. In the build sandbox there is no /dev/dri, but the
  # provider bootstrap is lazy — it only enumerates devices on first
  # InferenceSession creation, not on `import`. Safe to run.
  pythonImportsCheck = [ "onnxruntime" ];

  meta = {
    description = "ONNX Runtime with the OpenVINO Execution Provider (Intel prebuilt wheel)";
    homepage = "https://pypi.org/project/onnxruntime-openvino/";
    # MIT (onnxruntime) + Apache-2.0 (bundled OpenVINO runtime).
    license = with lib.licenses; [ mit asl20 ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}

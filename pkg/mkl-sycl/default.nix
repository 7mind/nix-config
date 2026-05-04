# Intel oneMKL 2025.3.1 — packaged just enough to satisfy ggml-sycl's
# `find_package(MKL REQUIRED)` with the namespaced `MKL::MKL_SYCL::BLAS`
# target. Sister-package to nixpkgs `mkl@2023.1.0`.
#
# Why a separate package, not a `mkl` override?
#   - nixpkgs' `mkl@2023.1.0` is widely depended on (numpy, scipy, octave, …).
#   - Bumping the global `mkl` cascades expensive rebuilds and risks ABI
#     drift in unrelated downstreams.
#   - Our only consumer is `pkg/llama-cpp-sycl/`. We pass this in via the
#     `mkl` argument override — the upstream package keeps 2023.1.
#
# Why 2025.3.1 specifically?
#   intel-llvm@unstable-2025-11-14 (in nixpkgs) ships `libsycl.so.8`.
#   Probed Intel's yum repo for which `libmkl_sycl_blas.so.*` matches:
#     - mkl@2023.1.0 → NEEDED libsycl.so.6  (✗ pkg already in nixpkgs)
#     - mkl@2025.0.x → NEEDED libsycl.so.8  (✓)
#     - mkl@2025.1.x → NEEDED libsycl.so.8  (✓)
#     - mkl@2025.2.x → NEEDED libsycl.so.8  (✓)
#     - mkl@2025.3.x → NEEDED libsycl.so.8  (✓)
#     - mkl@2026.0.0 → NEEDED libsycl.so.9  (✗ would need intel-llvm bump)
#   2025.3.1 is the latest 2025.x and gets the most recent bug fixes
#   while remaining ABI-compatible with our intel-llvm pin.
#
# Layout differences from nixpkgs mkl@2023.1.0:
#   - oneMKL ≥ 2024.0 splits the SYCL implementation per-domain
#     (mkl-sycl-blas, mkl-sycl-lapack, mkl-sycl-dft, …). ggml-sycl uses
#     BLAS only; we skip the rest to keep the closure small.
#   - Install paths under `mkl/2025.3/` (was `mkl/${version}/`).
#   - openmp + tbb directory layouts changed too — single `lib/` instead
#     of `linux/compiler/lib/intel64_lin/` and `intel64/gcc4.8/`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  rpmextract,
  validatePkgConfig,
}:

let
  mklVer    = "2025.3";
  mklRel    = "2025.3.1-8";
  openmpRel = "2025.3.3-30";
  tbbVer    = "2022.3";
  tbbRel    = "2022.3.1-400";

  baseUrl = "https://yum.repos.intel.com/oneapi";
  fetchRpm = name: hash: fetchurl {
    url = "${baseUrl}/${name}";
    inherit hash;
  };

  rpms = {
    # Runtime: libmkl_core.so, libmkl_intel_*, libmkl_*_thread.so, libmkl_rt.so, etc.
    mkl-core = fetchRpm
      "intel-oneapi-mkl-core-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-gTSZDJT86YEqIXU73PCg+1d07/LEA+bw67gGBLQw6F8=";

    # CMake config (MKLConfig.cmake), pkg-config files. Required by
    # ggml-sycl's `find_package(MKL REQUIRED)`.
    mkl-core-devel = fetchRpm
      "intel-oneapi-mkl-core-devel-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-4J3a/vpljVAX5b+gUooyO4BeoRZnRgq/KwhWAAh6ByQ=";

    # Classic C/Fortran headers — `mkl.h`, `mkl_blas.h`, etc. Pulled in
    # transitively via `oneapi/mkl/blas.hpp`.
    mkl-classic-include = fetchRpm
      "intel-oneapi-mkl-classic-include-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-W9+SAleIS7/YKbrn1Ib1jfUVFwku/1n+lbDEkdAwA2I=";

    # libmkl_sycl_blas.so.5 — the per-domain SYCL BLAS implementation
    # ggml-sycl actually links against.
    mkl-sycl-blas = fetchRpm
      "intel-oneapi-mkl-sycl-blas-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-l85MSBS3ZrXJAOPuzJMgj4bJe77sS5GzHHW0z+z8d60=";

    # SYCL headers: `oneapi/mkl.hpp`, `oneapi/mkl/blas.hpp`, …
    mkl-sycl-include = fetchRpm
      "intel-oneapi-mkl-sycl-include-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-6MsuM9wi11k6cdsbD5AkNdWz+VHflgbYDGteVtIkH0s=";

    # libiomp5.so — Intel OpenMP runtime, MKL's `intel_thread` backend.
    # We ship it but ggml-sycl uses the tbb_thread backend by default.
    openmp = fetchRpm
      "intel-oneapi-openmp-${mklVer}-${openmpRel}.x86_64.rpm"
      "sha256-8+1KTEY5H0cPsodo26yozJRXJxTVNjY1NBWqLrYfPVM=";

    # libtbb.so.12 — MKL's default tbb_thread backend at runtime.
    tbb = fetchRpm
      "intel-oneapi-tbb-${tbbVer}-${tbbRel}.x86_64.rpm"
      "sha256-OELnyp9df9un6y8LGV+1O1RtXPa3oMRgvXEOyp9yeec=";

    # TBB headers — required at MKL configure time even though ggml-sycl
    # itself doesn't directly include them.
    tbb-devel = fetchRpm
      "intel-oneapi-tbb-devel-${tbbVer}-${tbbRel}.x86_64.rpm"
      "sha256-My0Xqc/HrqXdubedsnys5jmSJ8l+2AUvqqEow7KKU2g=";
  };

  shlibExt = stdenvNoCC.hostPlatform.extensions.sharedLibrary;

in
stdenvNoCC.mkDerivation {
  pname = "mkl-sycl";
  version = mklRel;

  dontUnpack = true;

  nativeBuildInputs = [ rpmextract validatePkgConfig ];

  buildPhase = ''
    runHook preBuild
    ${lib.concatMapStringsSep "\n" (rpm: "rpmextract ${rpm}") (lib.attrValues rpms)}
    runHook postBuild
  '';

  # Layout produced by rpmextract:
  #   opt/intel/oneapi/mkl/2025.3/{lib,include,lib/cmake,lib/pkgconfig}
  #   opt/intel/oneapi/compiler/2025.3/lib/libiomp5.so   (from openmp rpm)
  #   opt/intel/oneapi/tbb/2022.3/{lib,include}
  #
  # We flatten everything into $out/{lib,include,lib/cmake,lib/pkgconfig}
  # so MKLConfig.cmake's `find_path` / `find_library` lookups land in one
  # prefix. CMake config files reference `${MKLROOT}` which must point at
  # a directory containing `lib/` and `include/` — we set MKLROOT in the
  # consumer derivation.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/cmake $out/lib/pkgconfig

    # MKL libs + headers
    cp -a opt/intel/oneapi/mkl/${mklVer}/lib/*${shlibExt}*  $out/lib/
    cp -r opt/intel/oneapi/mkl/${mklVer}/include/*          $out/include/
    cp -r opt/intel/oneapi/mkl/${mklVer}/lib/cmake/*        $out/lib/cmake/
    cp -a opt/intel/oneapi/mkl/${mklVer}/lib/pkgconfig/*.pc $out/lib/pkgconfig/

    # OpenMP runtime — only libiomp5.so + its support libs needed at runtime
    cp -a opt/intel/oneapi/compiler/${mklVer}/lib/libiomp5${shlibExt}* $out/lib/
    cp -a opt/intel/oneapi/compiler/${mklVer}/lib/libhwloc${shlibExt}* $out/lib/ || true

    # TBB
    cp -a opt/intel/oneapi/tbb/${tbbVer}/lib/libtbb${shlibExt}*    $out/lib/
    cp -a opt/intel/oneapi/tbb/${tbbVer}/lib/libhwloc${shlibExt}*  $out/lib/ || true
    cp -r opt/intel/oneapi/tbb/${tbbVer}/include/*                 $out/include/

    # Rewrite pkg-config + CMake to point at our flattened $out instead of
    # the MKLROOT placeholder Intel embeds.
    for f in $out/lib/pkgconfig/*.pc; do
      substituteInPlace "$f" \
        --replace-quiet "''${MKLROOT}" "$out" \
        --replace-quiet "lib/intel64" "lib"
      sed -r -i "s|^prefix=.*|prefix=$out|g" "$f"
    done

    # MKLConfig.cmake derives MKL_ROOT from its own location
    # (CMAKE_CURRENT_LIST_DIR/../..). With files under
    # $out/lib/cmake/mkl/MKLConfig.cmake, that resolves to $out/lib —
    # wrong. Provide a symlink so the climb lands at $out.
    mkdir -p $out/lib/cmake/mkl
    ln -sfn ../.. $out/lib/cmake/mkl/_root_climb_helper

    runHook postInstall
  '';

  # Per Intel SDK license: redistribute binaries unmodified.
  dontStrip = true;
  dontPatchELF = true;

  meta = with lib; {
    description = "Intel oneMKL 2025.3.1 with SYCL backend (libsycl.so.8 ABI)";
    homepage = "https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html";
    license = licenses.issl;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
}

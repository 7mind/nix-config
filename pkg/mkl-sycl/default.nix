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
# Why 2026.1.0 specifically?
#   nixpkgs `intel-llvm` is now 7.0.1 and ships `libsycl.so.9`.
#   mkl@2025.3.x NEEDs `libsycl.so.8`; dlopen of libggml-sycl.so then
#   fails (`libsycl.so.8 => not found`), llama.cpp reports "no usable
#   GPU", and the B70 falls back to CPU (~0.6 t/s on 27B).
#     - mkl@2025.3.x → NEEDED libsycl.so.8  (✗ vs intel-llvm 7.0.1)
#     - mkl@2026.1.0 → NEEDED libsycl.so.9  (✓ verified on
#       libmkl_sycl_blas.so.6 from the 2026.1.0-236 rpm)
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
  mklVer    = "2026.1";
  mklRel    = "2026.1.0-236";
  openmpRel = "2026.1.1-325";
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
      "sha256-fgZE+cZ93gPsAMKgvyYpB7kdg6JCNclVg69IZC2srhc=";

    # CMake config (MKLConfig.cmake), pkg-config files. Required by
    # ggml-sycl's `find_package(MKL REQUIRED)`.
    mkl-core-devel = fetchRpm
      "intel-oneapi-mkl-core-devel-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-YiAUZ6mzITc+N6yQCPKlUgBpPjTFZb5CwxfPCUya5Io=";

    # Classic C/Fortran headers — `mkl.h`, `mkl_blas.h`, etc. Pulled in
    # transitively via `oneapi/mkl/blas.hpp`.
    mkl-classic-include = fetchRpm
      "intel-oneapi-mkl-classic-include-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-L6txBebgH6pvvIh6f3EMBHX/WYh7H1cgLxVl8KYuZEY=";

    # libmkl_sycl_blas.so.6 — the per-domain SYCL BLAS implementation
    # ggml-sycl actually links against.
    mkl-sycl-blas = fetchRpm
      "intel-oneapi-mkl-sycl-blas-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-jIXH6t/VNPtUGe0OOcFteDvCj5wMfkclAbj/jImRbK4=";

    # SYCL headers: `oneapi/mkl.hpp`, `oneapi/mkl/blas.hpp`, …
    mkl-sycl-include = fetchRpm
      "intel-oneapi-mkl-sycl-include-${mklVer}-${mklRel}.x86_64.rpm"
      "sha256-QcRzl2G2MQTMnw/eGF14nMoGIqN92mkKROZFESJJ10w=";

    # libiomp5.so — Intel OpenMP runtime, MKL's `intel_thread` backend.
    # We ship it but ggml-sycl uses the tbb_thread backend by default.
    openmp = fetchRpm
      "intel-oneapi-openmp-${mklVer}-${openmpRel}.x86_64.rpm"
      "sha256-v+DG7g+DU2TYitM6YqmotLt0ZNk1VqefQ7V+e6ADXx0=";

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
  #   opt/intel/oneapi/mkl/2026.1/{lib,include,lib/cmake,lib/pkgconfig}
  #   opt/intel/oneapi/compiler/2026.1/lib/libiomp5.so   (from openmp rpm)
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

    # Globs under nullglob (nixpkgs stdenv) vanish when they match nothing
    # and `cp` then sees only the destination. Use find.
    find opt/intel/oneapi/mkl/${mklVer}/lib -maxdepth 1 -name '*${shlibExt}*' \
      -exec cp -a {} $out/lib/ \;
    cp -r opt/intel/oneapi/mkl/${mklVer}/include/. $out/include/
    cp -r opt/intel/oneapi/mkl/${mklVer}/lib/cmake/. $out/lib/cmake/
    find opt/intel/oneapi/mkl/${mklVer}/lib/pkgconfig -maxdepth 1 -name '*.pc' \
      -exec cp -a {} $out/lib/pkgconfig/ \;

    find opt/intel/oneapi/compiler/${mklVer}/lib -maxdepth 1 \
      \( -name 'libiomp5${shlibExt}*' -o -name 'libhwloc${shlibExt}*' \) \
      -exec cp -a {} $out/lib/ \;

    find opt/intel/oneapi/tbb/${tbbVer}/lib -maxdepth 1 \
      \( -name 'libtbb${shlibExt}*' -o -name 'libhwloc${shlibExt}*' \) \
      -exec cp -a {} $out/lib/ \;
    cp -r opt/intel/oneapi/tbb/${tbbVer}/include/. $out/include/

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
    description = "Intel oneMKL 2026.1.0 with SYCL backend (libsycl.so.9 ABI)";
    homepage = "https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html";
    license = licenses.issl;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
}

{ pkgs, src }:
let
  version = "0.9.12.1";
  system = pkgs.stdenv.hostPlatform.system;

  cefArch = {
    x86_64-linux = "x86_64";
    aarch64-linux = "aarch64";
  }.${system};

  cefSha256 = {
    x86_64 = "1qdlpq98jmi3r4rg9azkrprgxs5mvmg8svgfmkyg1ld1v3api80f";
    aarch64 = "1dxjv65rjkbnyc051hf505hd1ahw752lh59pimr50nkgkq07wqy8";
  }.${cefArch};

  runtimeLibs = with pkgs; [
    libx11
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxscrnsaver
    libxtst
    libxcb
    libxshmfence
    libxkbcommon
    gtk3
    glib
    pango
    cairo
    gdk-pixbuf
    atk
    at-spi2-atk
    at-spi2-core
    dbus
    alsa-lib
    cups
    libdrm
    mesa
    libGL
    libGLU
    expat
    nspr
    nss
    udev
    libgbm
    fontconfig
    freetype
    zlib
    bzip2
  ];

  patchedCef = pkgs.fetchurl {
    url = "https://github.com/ttalvitie/browservice/releases/download/v${version}/patched_cef_${cefArch}.tar.bz2";
    sha256 = cefSha256;
  };

  cefDllWrapper = pkgs.stdenv.mkDerivation {
    pname = "cef-dll-wrapper";
    inherit version;
    src = patchedCef;

    nativeBuildInputs = with pkgs; [
      cmake
      autoPatchelfHook
    ];
    buildInputs = runtimeLibs;

    dontConfigure = true;

    unpackPhase = ''
      mkdir -p cef
      tar xf "$src" -C cef --strip-components 1
    '';

    buildPhase = ''
      mkdir -p cef/releasebuild
      cd cef/releasebuild
      cmake -DCMAKE_BUILD_TYPE=Release ..
      make -j$NIX_BUILD_CORES libcef_dll_wrapper
    '';

    installPhase = ''
      cd "$NIX_BUILD_TOP"
      mkdir -p "$out/lib" "$out/include" "$out/Resources" "$out/Release"
      cp cef/releasebuild/libcef_dll_wrapper/libcef_dll_wrapper.a "$out/lib/"
      cp -r cef/Release/* "$out/Release/"
      cp -r cef/Resources/* "$out/Resources/"
      cp -r cef/include "$out/"
    '';
  };
in
pkgs.stdenv.mkDerivation {
  pname = "browservice";
  inherit version src;

  NIX_CFLAGS_COMPILE = "-include cstdint";

  nativeBuildInputs = with pkgs; [
    pkg-config
    autoPatchelfHook
    python3
  ];

  buildInputs = with pkgs; [
    pango
    libx11
    libxcb
    poco
    libjpeg
    zlib
    openssl
  ] ++ runtimeLibs;

  preBuild = ''
    mkdir -p cef/{Release,Resources,include,releasebuild/libcef_dll_wrapper}
    cp -r ${cefDllWrapper}/Release/* cef/Release/
    cp -r ${cefDllWrapper}/Resources/* cef/Resources/
    cp -r ${cefDllWrapper}/include/* cef/include/
    cp ${cefDllWrapper}/lib/libcef_dll_wrapper.a cef/releasebuild/libcef_dll_wrapper/

    pushd viceplugins/retrojsvice
    mkdir -p gen
    python3 gen_html_cpp.py > gen/html.cpp
    popd
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES release
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p "$out/bin" "$out/lib" "$out/share/browservice"
    cp release/bin/browservice "$out/bin/browservice-unwrapped"
    cp -rn cef/Release/* "$out/lib/" || true
    for item in cef/Resources/*; do
      if [ -d "$item" ]; then
        cp -rn "$item" "$out/lib/" || true
      else
        cp -n "$item" "$out/lib/" || true
      fi
    done
    cp release/bin/retrojsvice.so "$out/lib/"

    cat > "$out/bin/browservice" << 'WRAPPER'
    #!/usr/bin/env bash
    script_dir="$(dirname "$(readlink -f "$0")")"
    lib_dir="$(dirname "$script_dir")/lib"
    export LD_LIBRARY_PATH="$lib_dir''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    exec "$script_dir/browservice-unwrapped" "$@"
    WRAPPER
    chmod +x "$out/bin/browservice"
  '';

  postFixup = ''
    patchelf --set-rpath "$out/lib:${pkgs.lib.makeLibraryPath runtimeLibs}" "$out/bin/browservice-unwrapped"
    if [ -f "$out/lib/chrome-sandbox" ]; then
      chmod 755 "$out/lib/chrome-sandbox"
    fi
  '';

  meta = with pkgs.lib; {
    description = "Browser as a service for legacy web browsers via server-side rendering";
    homepage = "https://github.com/ttalvitie/browservice";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "browservice";
  };
}

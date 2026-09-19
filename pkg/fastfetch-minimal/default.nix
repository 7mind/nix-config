{ lib, cmake, fastfetch-unwrapped }:

fastfetch-unwrapped.overrideAttrs (old: {
  pname = "fastfetch-minimal";

  # The tmux status only needs procfs-backed CPU and memory modules.
  nativeBuildInputs = [ cmake ];
  buildInputs = [ ];

  postPatch = "";
  preConfigure = "";

  postInstall = ''
    rm -r \
      "$out/share/bash-completion" \
      "$out/share/fish" \
      "$out/share/zsh"
  '';

  cmakeFlags = [
    (lib.cmakeOptionType "filepath" "CMAKE_INSTALL_SYSCONFDIR" "${placeholder "out"}/etc")
  ] ++ map (feature: lib.cmakeBool "ENABLE_${feature}" false) [
    "VULKAN"
    "WAYLAND"
    "XCB_RANDR"
    "XRANDR"
    "DRM"
    "VADRM"
    "VAX11"
    "VDPAU"
    "GIO"
    "DCONF"
    "EET"
    "DBUS"
    "SQLITE3"
    "RPM"
    "IMAGEMAGICK7"
    "IMAGEMAGICK6"
    "CHAFA"
    "EGL"
    "GLX"
    "OPENCL"
    "FREETYPE"
    "PULSE"
    "DDCUTIL"
    "ELF"
    "ZLIB"
    "SYSTEM_YYJSON"
    "EMBEDDED_PCIIDS"
    "EMBEDDED_AMDGPUIDS"
    "LUA"
    "QUICKJS"
    "LIBZFS"
  ] ++ [
    (lib.cmakeBool "BUILD_FLASHFETCH" false)
  ];

  meta = old.meta // {
    description = "Fastfetch without optional external library integrations";
  };
})

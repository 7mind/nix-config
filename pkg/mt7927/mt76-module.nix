# Out-of-tree MediaTek MT7927 (Filogic 380, internally MT6639) kernel modules.
#
# Mirrors jetm/mediatek-mt7927-dkms v2.17-2: mt76 + bluetooth source from the
# pristine linux-7.3 tarball, then the remaining out-of-tree patches (4 AP-mode
# additions + compatibility shims). Linux 7.3 absorbs the two teardown
# backports; Sean Wang's MT7927 series landed in mainline 7.2.
#
# Built against the *running* kernel's headers. Compat shims cover host
# kernels back through 7.0. Modules install into `.../updates/`, which
# depmod/modprobe prefer over the identically-named in-tree modules.
#
# Bluetooth: MT6639 is native from linux 7.1. The out-of-tree btusb/btmtk
# modules add HP EliteMini ID 0489:e156 and firmware/PM fixes, but replace
# the stack for every BT device, so they are skipped on 7.1+ (same default as
# jetm 2.17-2). Firmware for the in-tree BT driver is still the ASUS blob
# — see ./firmware.nix.
{
  lib,
  stdenv,
  fetchurl,
  kernel,
  kmodigest,
}:

let
  # Kernel version whose mt76/bluetooth subtree the patches target. Pinned to
  # match jetm's v2.17-2 `_mt76_kver`; bump in lockstep with the patch set.
  mt76Kver = "7.3";

  # Pristine upstream tarball (sha256 from jetm's PKGBUILD). We only consume the
  # mt76 + bluetooth subtrees from it; building happens against `kernel.dev`.
  linuxSrc = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${lib.versions.major mt76Kver}.x/linux-${mt76Kver}.tar.xz";
    hash = "sha256-hzY8JPEOBjIes2J2VSEJTpRHH2v/i84taz5A858ASVM=";
  };

  # jetm 2.17-2: skip out-of-tree btusb/btmtk once the host has native MT6639.
  buildBluetooth = lib.versionOlder (lib.versions.majorMinor kernel.version) "7.1";
in
stdenv.mkDerivation {
  pname = "mt7927-mt76";
  # Tie the version to the kernel: extraModulePackages must be rebuilt per
  # kernel, and this keeps the store path distinct across kernel bumps.
  version = "2.17-${kernel.version}";

  src = ./.;

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ kmodigest ];

  # The patches are context diffs against linux-7.3; -p1 from the respective
  # subtree root, applied in the same order as jetm's Makefile `sources` target.
  buildPhase = ''
    runHook preBuild

    mkdir -p build/mt76 build/bluetooth
    tar -xf ${linuxSrc} --strip-components=6 -C build/mt76 \
      linux-${mt76Kver}/drivers/net/wireless/mediatek/mt76
    tar -xf ${linuxSrc} --strip-components=3 -C build/bluetooth \
      linux-${mt76Kver}/drivers/bluetooth

    echo "==> Applying WiFi (mt76) patches"
    for p in patches/mt7927-wifi-*.patch; do
      echo "  $(basename "$p")"
      patch -d build/mt76 -p1 < "$p" || exit 1
    done

    ${lib.optionalString buildBluetooth ''
      echo "==> Applying Bluetooth (btusb/btmtk) patches"
      for p in patches/mt6639-bt-[0-9]*.patch patches/mt6639-bt-compat-*.patch; do
        echo "  $(basename "$p")"
        patch -d build/bluetooth -p1 < "$p" || exit 1
      done
    ''}

    echo "==> Installing Kbuild + compat glue"
    cp mt76.Kbuild   build/mt76/Kbuild
    cp mt7921.Kbuild build/mt76/mt7921/Kbuild
    cp mt7925.Kbuild build/mt76/mt7925/Kbuild
    cp bluetooth.Makefile build/bluetooth/Makefile
    mkdir -p build/mt76/compat/include/linux/soc/airoha
    cp compat-airoha-offload.h \
      build/mt76/compat/include/linux/soc/airoha/airoha_offload.h

    kdir=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    ${lib.optionalString buildBluetooth ''
      echo "==> Building bluetooth modules"
      make -C "$kdir" M="$(pwd)/build/bluetooth" modules
    ''}
    echo "==> Building mt76 modules"
    make -C "$kdir" M="$(pwd)/build/mt76" modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/updates"
    mkdir -p "$instdir"
    find build \( -name 'btusb.ko' -o -name 'btmtk.ko' -o -path '*mt76*.ko' \) \
      -exec cp -v {} "$instdir/" \;
    # nixpkgs' kernel signs modules at `modules_install` (cmd_sign overridden
    # to kmodigest) and the kmod aggregator concatenates the per-module
    # `*.ko.cer` certificates into modules.cer. This package installs the
    # modules manually, bypassing modinst, so sign them here explicitly.
    for ko in "$instdir"/*.ko; do
      kmodigest "$ko"
    done
    runHook postInstall
  '';

  meta = {
    description = "Out-of-tree MediaTek MT7927/MT6639 (Filogic 380) WiFi 7 + Bluetooth kernel modules";
    homepage = "https://github.com/jetm/mediatek-mt7927-dkms";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}

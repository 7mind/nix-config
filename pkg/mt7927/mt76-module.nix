# Out-of-tree MediaTek MT7927 (Filogic 380, internally MT6639) kernel modules.
#
# MT7927 is NOT supported by mainline as of linux 7.0.x: the in-tree mt7925
# PCI table carries only 0x7925/0x0717, and drivers/bluetooth has no MT6639.
# Javier Tia (jetm) maintains the patch series that extends the mt7925e/mt76
# stack (and btusb/btmtk) for the 0x7927 chip; it is under review upstream
# (wifi: mt76: mt7925: add MT7927 (Filogic 380) support) but not yet merged.
#
# This derivation mirrors jetm/mediatek-mt7927-dkms exactly: it takes the mt76
# and bluetooth source from the pristine linux-7.0 tarball (NOT nixpkgs' 7.0.10
# tree — the patches are authored against 7.0 base context), applies the
# vendored GPL-2.0 patch set + custom Kbuild, and builds the modules against the
# *running* kernel's headers. The result installs into `.../updates/`, which
# depmod/modprobe prefer over the identically-named in-tree modules, so the
# patched mt7925e/mt76/btusb shadow the stock ones without a blacklist.
#
# Firmware (the runtime blobs the patched driver request_firmware()s) is a
# separate, non-redistributable package — see ./firmware.nix.
{
  lib,
  stdenv,
  fetchurl,
  kernel,
}:

let
  # Kernel version whose mt76/bluetooth subtree the patches target. Pinned to
  # match jetm's `_mt76_kver`; bump in lockstep with the vendored patch set.
  mt76Kver = "7.0";

  # Pristine upstream tarball (sha256 from jetm's PKGBUILD). We only consume the
  # mt76 + bluetooth subtrees from it; building happens against `kernel.dev`.
  linuxSrc = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${lib.versions.major mt76Kver}.x/linux-${mt76Kver}.tar.xz";
    hash = "sha256-u39tgLOHx1e30Uu5MCj8uQ95PFwNNnc27oFaEAs4kfA=";
  };
in
stdenv.mkDerivation {
  pname = "mt7927-mt76";
  # Tie the version to the kernel: extraModulePackages must be rebuilt per
  # kernel, and this keeps the store path distinct across kernel bumps.
  version = "2.12-${kernel.version}";

  src = ./.;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # The patches are context diffs against linux-7.0; -p1 from the respective
  # subtree root, applied in the same order as jetm's Makefile `sources` target.
  buildPhase = ''
    runHook preBuild

    mkdir -p build/mt76 build/bluetooth
    tar -xf ${linuxSrc} --strip-components=6 -C build/mt76 \
      linux-${mt76Kver}/drivers/net/wireless/mediatek/mt76
    tar -xf ${linuxSrc} --strip-components=3 -C build/bluetooth \
      linux-${mt76Kver}/drivers/bluetooth

    echo "==> Applying WiFi (mt76) patches"
    patch -d build/mt76 -p1 < patches/mt7902-wifi-6.19.patch
    for p in patches/mt7927-wifi-*.patch; do
      echo "  $(basename "$p")"
      patch -d build/mt76 -p1 < "$p"
    done

    echo "==> Applying Bluetooth (btusb/btmtk) patches"
    for p in patches/mt6639-bt-[0-9]*.patch patches/mt6639-bt-compat-*.patch; do
      echo "  $(basename "$p")"
      patch -d build/bluetooth -p1 < "$p"
    done

    echo "==> Installing Kbuild + compat glue"
    cp mt76.Kbuild   build/mt76/Kbuild
    cp mt7921.Kbuild build/mt76/mt7921/Kbuild
    cp mt7925.Kbuild build/mt76/mt7925/Kbuild
    cp bluetooth.Makefile build/bluetooth/Makefile
    mkdir -p build/mt76/compat/include/linux/soc/airoha
    cp compat-airoha-offload.h \
      build/mt76/compat/include/linux/soc/airoha/airoha_offload.h

    kdir=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    echo "==> Building bluetooth modules"
    make -C "$kdir" M="$(pwd)/build/bluetooth" modules
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

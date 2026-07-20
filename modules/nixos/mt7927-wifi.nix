# MediaTek MT7927 (Filogic 380, PCI 14c3:7927, internally MT6639) WiFi 7 +
# Bluetooth. No mainline support as of linux 7.1.x; wires in jetm's out-of-tree
# v2.13-1 mt76/btusb patch set + firmware, based on Linux 7.1.3 and carrying
# compatibility shims for Linux 7.0. Drop this module once mainline
# (wifi: mt76: mt7925: add MT7927 support) has landed.
{ config, lib, pkgs, cfg-meta, ... }:

let
  cfg = config.smind.hw.mt7927;
  kernel = config.boot.kernelPackages.kernel;
  kernelMM = lib.versions.majorMinor kernel.version;

  # ASUS driver ZIP, vendored in the private submodule. `builtins.path` so the
  # firmware derivation rehashes only when the ZIP bytes change.
  zipName = "DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip";
  driverZip = builtins.path {
    path = "${cfg-meta.paths.private}/pkg/mt7927-firmware/${zipName}";
    name = zipName;
  };

  mt76 = pkgs.callPackage ../../pkg/mt7927/mt76-module.nix { inherit kernel; };
  firmware = pkgs.callPackage ../../pkg/mt7927/firmware.nix { inherit driverZip; };
in
{
  options.smind.hw.mt7927.enable = lib.mkEnableOption ''
    MediaTek MT7927 (Filogic 380) WiFi 7 + Bluetooth via the out-of-tree
    mt76/btusb patch set (jetm/mediatek-mt7927-dkms). Requires the ASUS driver
    ZIP in the store for firmware — see pkg/mt7927/firmware.nix
  '';

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem kernelMM [ "7.0" "7.1" ];
        message =
          "smind.hw.mt7927: the vendored mt76 patch set supports linux 7.0 and 7.1, "
          + "but the kernel is ${kernel.version}. Re-validate the patches "
          + "(pkg/mt7927) against the new kernel, or drop this module if "
          + "MT7927 support has reached mainline.";
      }
    ];

    # `updates/` outranks the in-tree mt7925e/mt76/btusb in modprobe's search
    # order, so the patched modules shadow the stock ones with no blacklist.
    # Autoload is driven by the new PCI/USB aliases when the device is present.
    boot.extraModulePackages = [ mt76 ];
    hardware.firmware = [ firmware ];
  };
}

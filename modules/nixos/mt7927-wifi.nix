# MediaTek MT7927 (Filogic 380, PCI 14c3:7927, internally MT6639) WiFi 7 +
# Bluetooth. Mainline 7.2 has the MT7927 WiFi series; we still vendor
# jetm v2.14-6 so 7.0/7.1 hosts get that source plus the remaining AP-mode
# patches and pre-7.2 compat shims. Drop this module once the host kernel
# is 7.2+ *and* the four AP-mode additions have landed (or are unneeded).
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
        assertion = lib.elem kernelMM [ "7.0" "7.1" "7.2" ];
        message =
          "smind.hw.mt7927: the vendored mt76 patch set (jetm v2.14-6, linux 7.2 source) "
          + "supports linux 7.0–7.2, but the kernel is ${kernel.version}. "
          + "Re-validate the patches (pkg/mt7927) against the new kernel, or drop "
          + "this module if the remaining AP-mode patches have reached mainline.";
      }
    ];

    # `updates/` outranks the in-tree mt7925e/mt76/btusb in modprobe's search
    # order, so the patched modules shadow the stock ones with no blacklist.
    # Autoload is driven by the new PCI/USB aliases when the device is present.
    boot.extraModulePackages = [ mt76 ];
    hardware.firmware = [ firmware ];
  };
}

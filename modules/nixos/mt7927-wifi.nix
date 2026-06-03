# MediaTek MT7927 (Filogic 380) WiFi 7 + Bluetooth enablement.
#
# The chip (PCI 14c3:7927, internally MT6639) has no mainline support as of
# linux 7.0.x. This wires in jetm's out-of-tree mt76/btusb patch set as an
# extraModulePackage plus the user-supplied firmware. Both are pinned to the
# 7.0 patch base; the assertion below makes a future kernel bump fail loudly
# rather than silently ship a stale, mis-built driver — at which point check
# whether mainline (wifi: mt76: mt7925: add MT7927 support) has landed and this
# module can be dropped entirely.
{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hw.mt7927;
  kernel = config.boot.kernelPackages.kernel;
  kernelMM = lib.versions.majorMinor kernel.version;

  mt76 = pkgs.callPackage ../../pkg/mt7927/mt76-module.nix { inherit kernel; };
  firmware = pkgs.callPackage ../../pkg/mt7927/firmware.nix { };
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
        assertion = kernelMM == "7.0";
        message =
          "smind.hw.mt7927: the vendored mt76 patch set targets linux 7.0, "
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

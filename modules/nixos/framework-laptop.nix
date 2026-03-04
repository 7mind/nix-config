{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hw.framework-laptop;
  kernelVersion = config.boot.kernelPackages.kernel.version;
  isKernel612 = lib.versionAtLeast kernelVersion "6.12" && lib.versionOlder kernelVersion "6.13";
in
{
  options.smind.hw.framework-laptop = {
    enable = lib.mkEnableOption ''
      Framework laptop hardware support.
      Enables framework-laptop-kmod, IIO sensors, ALS udev rules, and wluma polkit rules
    '';

    adaptive-backlight-disable = lib.mkEnableOption ''
      amdgpu adaptive backlight disable (amdgpu.abmlevel=0).
      Prevents ABM from adjusting panel brightness based on content, which can cause flickering
    '' // { default = cfg.enable; };

    kernelPatches = {
      vpe-dpm0.enable = lib.mkEnableOption ''
        amdgpu VPE Strix Point DPM0 fix.
        Adds IP_VERSION(6, 1, 0) to the DPM0 power-down check in amdgpu_vpe.c
      '' // { default = cfg.enable; };

      ath12k-pairwise-key.enable = lib.mkEnableOption ''
        ath12k WCN7850 pairwise key ordering fix (kernel 6.12 only).
        Backport of upstream commit 66e865f9dc78 — WCN7850 firmware requires PTK before GTK.
        https://bugzilla.kernel.org/show_bug.cgi?id=218733
      '' // { default = cfg.enable && isKernel612; };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # --- Base Framework laptop support ---
    {
      environment.systemPackages = with pkgs; [
        fw-ectool # Framework EC tool for fan control, battery charge limit, etc.
        framework-tool # Swiss army knife CLI for Framework laptops
        framework-tool-tui # TUI for controlling Framework hardware
      ];

      # Framework laptop kernel module for battery charge limit and LED control
      boot.extraModulePackages = [ config.boot.kernelPackages.framework-laptop-kmod ];
      boot.kernelModules = [ "framework_laptop" ];

      # ALS (ambient light sensor) for wluma
      hardware.sensor.iio.enable = true;

      # Enable ALS illuminance scan element for buffer mode (Framework 16)
      services.udev.extraRules = lib.mkAfter ''
        ACTION=="add", SUBSYSTEM=="iio", ATTR{name}=="als", ATTR{scan_elements/in_illuminance_en}="1"
      '';

      # Allow wluma to claim sensors from iio-sensor-proxy
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "net.hadess.SensorProxy.claim-sensor") {
            return polkit.Result.YES;
          }
        });
      '';
    }

    # --- Kernel params ---

    (lib.mkIf cfg.adaptive-backlight-disable {
      boot.kernelParams = [ "amdgpu.abmlevel=0" ];
    })

    # --- Kernel patches ---

    (lib.mkIf cfg.kernelPatches.vpe-dpm0.enable {
      boot.kernelPatches = [
        {
          name = "amdgpu-vpe-strix-point-dpm0-fix";
          patch = pkgs.writeText "vpe-strix-point.patch" ''
            --- a/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
            +++ b/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
            @@ -325,6 +325,8 @@ static bool vpe_need_dpm0_at_power_down(struct amdgpu_device *adev)
             {
             	switch (amdgpu_ip_version(adev, VPE_HWIP, 0)) {
            +	case IP_VERSION(6, 1, 0):
            +		return true; /* Strix Point needs DPM0 check regardless of PMFW version */
             	case IP_VERSION(6, 1, 1):
             		return adev->pm.fw_version < 0x0a640500;
             	default:
          '';
        }
      ];
    })

    (lib.mkIf cfg.kernelPatches.ath12k-pairwise-key.enable {
      boot.kernelPatches = [
        {
          # Backport of upstream commit 66e865f9dc78 ("wifi: ath12k: install pairwise key first")
          # WCN7850 firmware requires PTK before GTK; without this fix the EAPOL handshake
          # fails in a loop (PREV_AUTH_NOT_VALID deauth). Not backported to 6.12 LTS upstream.
          name = "ath12k-wcn7850-install-pairwise-key-first";
          patch = ./patches/ath12k-pairwise-key-6.12.patch;
        }
      ];
    })
  ]);
}

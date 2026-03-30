{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hw.framework-laptop;
  frameworkToolExecutable = lib.getExe' pkgs.framework-tool "framework_tool";
  macLikeModifiersRemapCommands = ''
    # Framework Laptop 13 keyboard table and scan code examples:
    # https://github.com/rs-gh-asdf/framework-system/blob/af23ae7bf5cfbcb20bf2d3799a281ccf01ca40c6/EXAMPLES.md
    # Framework EC firmware defines SCANCODE_FN = 0x00ff.
    # The Framework 13 matrix places physical left ctrl at row 1 col 12 and physical fn at row 2 col 2.
    # Remap both positions directly so the layout does not depend on the BIOS ctrl/fn swap setting.
    ${frameworkToolExecutable} --remap-key 1 12 0x00ff
    # physical fn -> lmeta
    ${frameworkToolExecutable} --remap-key 2 2 0xe01f
    # lmeta -> lalt
    ${frameworkToolExecutable} --remap-key 3 1 0x0011
    # lalt -> lctl
    ${frameworkToolExecutable} --remap-key 1 3 0x0014
    # ralt -> rctl
    ${frameworkToolExecutable} --remap-key 0 3 0xe014
    # rctl -> ralt
    ${frameworkToolExecutable} --remap-key 0 12 0xe011
  '';
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

    mac-like-modifiers-remap = lib.mkEnableOption ''
      Framework Laptop 13 initrd key remap for mac-like modifiers.
      Applies an EC-level swap so Command/Option/Control behave like macOS-style modifiers before userspace starts
    '';
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

    (lib.mkIf cfg.mac-like-modifiers-remap {
      assertions = [
        {
          assertion = config.boot.initrd.systemd.enable;
          message = "smind.hw.framework-laptop.mac-like-modifiers-remap requires boot.initrd.systemd.enable";
        }
      ];

      boot.initrd.systemd = {
        initrdBin = [ pkgs.framework-tool ];

        services.framework-laptop13-mac-like-modifiers-remap = {
          description = "Apply Framework Laptop 13 mac-like modifier remap";
          wantedBy = [ "initrd.target" ];
          after = [ "systemd-modules-load.service" ];
          before = [ "initrd.target" ];
          serviceConfig.Type = "oneshot";
          script = macLikeModifiersRemapCommands;
        };
      };

      systemd.services.framework-laptop13-mac-like-modifiers-remap-resume = {
        description = "Re-apply Framework Laptop 13 mac-like modifier remap after resume";
        before = [ "sleep.target" ];
        wantedBy = [ "sleep.target" ];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "framework-laptop13-mac-like-modifiers-remap-suspend" ''
            set -euo pipefail
          '';
          ExecStop = pkgs.writeShellScript "framework-laptop13-mac-like-modifiers-remap-resume" ''
            set -euo pipefail
            ${pkgs.util-linux}/bin/logger -p user.info "Re-applying Framework Laptop 13 mac-like modifier remap after resume"
            ${macLikeModifiersRemapCommands}
          '';
        };
      };
    })

  ]);
}

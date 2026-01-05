{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

  services.wluma = {
    enable = true;
    settings = {
      als.iio = {
        path = "/sys/bus/iio/devices";
        thresholds = {
          "0" = "0";
          "5" = "5";
          "10" = "10";
          "20" = "20";
          "30" = "30";
          "50" = "50";
          "80" = "80";
          "250" = "250";
          "500" = "500";
        };
      };
      output.backlight = [{
        name = "eDP-1";
        path = "/sys/class/backlight/nvidia_wmi_ec_backlight";
        capturer = "none";
      }];
    };
  };

  smind.hm = {
    vscodium.fontSize = 14;
    ghostty.fontSize = 11;
    dev.llm.devstralContextSize = 16384;

    desktop.cosmic.minimal-keybindings = true;

    # Resource-limited Electron apps
    electron-wrappers = {
      enable = true;
      cpuQuota = "200%";
      cpuWeight = 70;
      memoryMax = "4G";
      slack.enable = true;
      slack.netns = "vpn";
      element.enable = true;
    };


  };
}

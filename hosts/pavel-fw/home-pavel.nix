{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

  home.packages = [
    pkgs.fractal-tray
  ];

  services.wluma = {
    enable = true;
    settings = {
      als.iio = {
        path = "/sys/bus/iio/devices";
        thresholds = {
          "0" = "night";
          "20" = "dim";
          "80" = "normal";
          "250" = "bright";
          "500" = "outdoors";
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
    roles.desktop = true;
    wezterm.fontSize = 11;
    vscodium.fontSize = 14;
    ghostty.enable = true;
    ghostty.fontSize = 11;

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

    autostart.programs = [
      # {
      #   name = "element-main";
      #   exec = "${config.home.profileDirectory}/bin/element-desktop";
      # }
      {
        name = "slack";
        exec = "${config.home.profileDirectory}/bin/slack";
      }
      {
        name = "fractal";
        exec = "${config.home.profileDirectory}/bin/fractal --minimized";
      }
    ];
  };
}

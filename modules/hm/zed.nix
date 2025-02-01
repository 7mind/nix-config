{ config, lib, pkgs, cfg-flakes, cfg-packages, cfg-meta, override_pkg, ... }:

{
  options = {
    smind.hm.zed.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.zed.enable {

    programs.zed-editor = {
      enable = true;
      extensions = [
        "nix"
      ];
      userSettings = {
        features = {
          copilot = false;
        };
        telemetry = {
          metrics = false;
        };
        vim_mode = false;
        ui_font_size = 16;
        buffer_font_size = 16;
      };
      userKeymaps =
        [ ];
      extraPackages = [ ];
    };

  };
}


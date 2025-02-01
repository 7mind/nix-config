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
        "html"
        "toml"
        "dockerfile"
        "java"
        "git-firefly"
        "latex"
        "make"
        "xml"
        "swift"
        "lua"
        "csharp"
        "kotlin"
        "basher"
        "haskell"
        "ini"
      ];

      userSettings = {
        autosave = {
          after_delay = {
            milliseconds = 250;
          };
        };

        features = {
          copilot = false;
        };
        telemetry = {
          diagnostics = false;
          metrics = false;
        };
        vim_mode = false;
        ui_font_size = 16;
        buffer_font_size = 16;
        auto_update = false;
      };
      userKeymaps =
        [ ];
      extraPackages = [ ];
    };

  };
}


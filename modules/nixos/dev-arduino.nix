{ config, lib, pkgs, ... }:
let
  cfg = config.smind.dev.arduino;
in
{
  options.smind.dev.arduino = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop;
      description = "Enable Arduino development tools and serial access rules";
    };

    ide = {
      enable = lib.mkEnableOption "Arduino IDE package";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.arduino-ide;
        description = "Arduino IDE package to install when ide.enable is true";
      };
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "pavel" ];
      description = "Users to add to the dialout group for serial device access";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [ pkgs.arduino-cli ]
      ++ lib.optional cfg.ide.enable cfg.ide.package;

    services.udev.extraRules = lib.mkAfter ''
      # QinHeng Electronics CH340 USB-serial converter (1a86:7523)
      SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0660", GROUP="dialout", TAG+="uaccess"
    '';

    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = [ "dialout" ];
    });
  };
}

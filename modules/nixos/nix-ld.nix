{ pkgs, lib, config, ... }: {
  options = {
    smind.nix-ld.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.nix-ld.enable {
    programs.nix-ld = {
      enable = true;
      package = pkgs.nix-ld-rs;
      libraries = with pkgs; [
        wayland
      ];
    };
  };
}

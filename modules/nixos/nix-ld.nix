{ pkgs, lib, config, ... }: {
  options = {
    smind.environment.nix-ld.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable nix-ld for running unpatched binaries";
    };
  };

  config = lib.mkIf config.smind.environment.nix-ld.enable {
    programs.nix-ld = {
      enable = true;
      package = pkgs.nix-ld;
      libraries = with pkgs; [
        wayland
      ];
    };
  };
}

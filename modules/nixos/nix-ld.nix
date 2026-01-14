{ pkgs, lib, config, ... }: {
  options = {
    smind.environment.nix-ld.enable = lib.mkEnableOption "nix-ld for running unpatched binaries";
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

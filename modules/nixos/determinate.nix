{ lib, config, pkgs, ... }: {
  options = {
    smind.nix.determinate = {
      enable = lib.mkEnableOption "Determinate Nix with FlakeHub cache";
    };
  };

  config = lib.mkIf config.smind.nix.determinate.enable {
    smind.nix.customize = lib.mkForce false;

    nixpkgs.config.allowUnfree = true;

    nix.settings = {
      connect-timeout = 5;
      keep-going = true;
      eval-cores = 0;
    };

    environment.systemPackages = [ pkgs.fh ];
  };
}

{ config, lib, ... }:

{
  options = {
    smind.docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.docker.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
      # extraPackages = with pkgs; [ aardvark-dns netavark zfs ];
      # defaultNetwork.settings.dns_enabled = true;
    };
  };
}

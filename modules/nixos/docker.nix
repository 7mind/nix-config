{ config, lib, ... }:

{
  options = {
    smind.containers.docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Podman with Docker compatibility";
    };
  };

  config = lib.mkIf config.smind.containers.docker.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
      # extraPackages = with pkgs; [ aardvark-dns netavark zfs ];
      # defaultNetwork.settings.dns_enabled = true;
    };
  };
}

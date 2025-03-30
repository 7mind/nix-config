{ config, lib, pkgs, cfg-const, cfg-meta, ... }:

{
  imports = [
    ./hardware-configuration.nix
    "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
    "${cfg-meta.paths.private}/modules/nix/github-agent.nix"
    "${cfg-meta.paths.private}/modules/nix/wg-o2.nix"
  ];

  networking = {
    hostName = "o2";
    domain = "7mind.io";
    hostId = "aabb0002";

    useNetworkd = true;

    useDHCP = false;
    interfaces.enp0s6.useDHCP = true;

    firewall.enable = true;
  };

  users = {
    users = {
      root = {
        openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel ++ cfg-const.ssh-keys-nix-builder;
      };
    };
  };

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFODTDmFlPuJ3XHW24LYLcJrTZF5+fg6HNUiHKKuJXfD";
  };


  environment.systemPackages = with pkgs; [
  ];

  home-manager.users.root = import ./home-root.nix;

  smind = {
    roles.server.oracle-cloud = true;

    locale.ie.enable = true;

    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    net.main-interface = "enp0s6";
    net.tailscale.enable = true;

    ssh.permissive = false;
    ssh.safe = true;

    router.enable = true;

    home-manager.enable = true;
  };
}


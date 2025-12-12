{ cfg-meta, cfg-const, lib, ... }:

{
  imports = [
    # ../../consts.nix
    "${cfg-meta.paths.modules}/nixos/ssh-safe.nix"
  ];

  smind = {
    ssh.safe.enable = true;
  };

  users = {
    users.root = {
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
      #password = "nixos";
    };
  };

  system.stateVersion = cfg-meta.state-version-system;

  services.openssh = {
    settings = { PermitRootLogin = lib.mkForce "yes"; };
  };

  networking = {
    # Use systemd-resolved inside the container
    # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
    useHostResolvConf = false;

    enableIPv6 = false;
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;
  };

  systemd.network.enable = true;

  services.resolved = {
    enable = true;
    extraConfig = "Cache=no-negative";
    llmnr = "false";
  };
}

{ cfg-meta, cfg-const, lib, ... }:

{
  imports = [
    # ../../consts.nix
    "${cfg-meta.paths.modules}/nixos/ssh.nix"
  ];

  smind = {
    ssh.mode = "safe";
  };

  users = {
    users.root = {
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
      #password = "nixos";
    };
  };

  system.stateVersion = cfg-meta.state-version-system;

  services.openssh = {
    settings = {
      PermitRootLogin = lib.mkDefault "prohibit-password";
      AuthorizedKeysFile =
        "/etc/ssh/authorized_keys.d/%u .ssh/authorized_keys .ssh/authorized_keys2";
    };
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
  systemd.network.wait-online.enable = false;

  services.resolved = {
    enable = true;
    settings = {
      Resolve = {
        Cache = "no-negative";
        LLMNR = "false";
      };
    };
  };
}

{ cfg-meta, cfg-const, lib, pkgs, ... }:

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

  # Containers have no use for the NixOS options manual / manpages.
  # Skips rendering work at build time and shaves a few MB per container.
  # (Doesn't measurably affect eval time — option-doc generation is lazy
  # and toplevel doesn't force it — but it's free hygiene.)
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;

  environment.systemPackages = [
    pkgs.ghostty.terminfo
  ];

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

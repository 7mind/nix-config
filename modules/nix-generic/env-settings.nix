{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.environment.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sane environment defaults";
    };

    smind.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable full documentation generation";
    };
  };

  config = lib.mkIf config.smind.environment.sane-defaults.enable {

    documentation = lib.mkIf config.smind.environment.all-docs.enable
      {
        man.enable = true;
        info.enable = true;
        doc.enable = true;
      } // (if cfg-meta.isLinux then {
      nixos.enable = true;
      dev.enable = true;
    } else { });

    programs =
      if cfg-meta.isLinux then {
        mtr.enable = true;
        trippy.enable = true;
      } else { };

    environment.systemPackages = with pkgs; [
      # file managers
      #far2l broken
      mc
      nnn

      # editors
      nano

      # networking
      wget
      curl
      rsync
      ipcalc

      trippy
      mtr
      nmap
      rustscan

      bind.dnsutils
      tcpdump
      whois
      wakelan
      miniupnpc
      ookla-speedtest
      iperf
      wireguard-tools
      rsync

      mosh

      # disk tools
      file
      ncdu
      dust
      tree
      lsd
      rename
      ripgrep
      fd # TODO:

      # monitoring
      htop
      zenith
      bandwhich

      # terminal
      tmux
      zellij
      lsix # show thumbnails in the terminal
      spacer
      viddy
      tealdeer

      # arc
      unar
      zip
      unzip
      p7zip

      # system tools
      killall
      coreutils

      # pipe tools
      pv
      gnused
      sd # TODO
      mdcat
      bat

      # security
      age
      gnupg
      #inputs.agenix.packages."${system}".default

      # benchmark
      stress
      hyperfine
    ] ++ (if cfg-meta.isLinux then with pkgs; [
      # system tools
      d-spy
      radvd
    ] else [ ]);
  };
}

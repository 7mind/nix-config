{ config, lib, pkgs, inputs, ... }:

{
  options = {
    smind.environment.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };

    smind.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.environment.sane-defaults.enable {

    documentation = lib.mkIf config.smind.environment.all-docs.enable {
      nixos.enable = true;
      man.enable = true;
      info.enable = true;
      doc.enable = true;
      dev.enable = true;
    };

    environment.systemPackages = with pkgs; [

      # file managers
      far2l
      mc
      nnn

      # editors
      nano

      # networking
      wget
      curl
      rsync
      ipcalc
      nmap
      bind.dnsutils
      tcpdump
      whois
      wakelan
      miniupnpc
      ookla-speedtest
      iperf
      wireguard-tools
      rsync

      # disk tools
      file
      ncdu
      du-dust
      tree
      lsd
      rename
      ripgrep
      fd # TODO:

      # monitoring
      htop
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
      d-spy

      # pipe tools
      pv
      gnused
      sd # TODO
      mdcat
      bat

      # security
      age
      gnupg
      inputs.agenix.packages."${system}".default

      # benchmark
      stress
      hyperfine
    ];
  };
}

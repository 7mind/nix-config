{ config, lib, pkgs, cfg-meta, inputs, ... }:

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

    smind.environment.fileManagers = lib.genAttrs [ "mc" "far2l" "f4" ] (name: {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install ${name}";
      };
    });
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = with pkgs;
        lib.optional config.smind.environment.fileManagers.mc.enable mc
        ++ lib.optional config.smind.environment.fileManagers.far2l.enable
          (if config.smind.isDesktop then far2l else far2l-noui)
        ++ lib.optional config.smind.environment.fileManagers.f4.enable
          (if config.smind.isDesktop then
            inputs.f4.packages.${pkgs.stdenv.hostPlatform.system}.f4-gui
          else
            inputs.f4.packages.${pkgs.stdenv.hostPlatform.system}.f4-tty);
    }
    (lib.mkIf config.smind.environment.sane-defaults.enable {

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
      nnn

      nano

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

      file
      ncdu
      dust
      tree
      lsd
      rename
      ripgrep
      fd

      htop
      btop
      bottom
      zenith
      bandwhich

      tmux
      zellij
      lsix # show thumbnails in the terminal
      qrencode
      spacer
      viddy
      tealdeer

      unar
      zip
      unzip
      p7zip

      killall
      coreutils
      parallel

      pv
      gnused
      sd
      mdcat
      bat

      age
      gnupg

      stress
      hyperfine
    ] ++ (if cfg-meta.isLinux then with pkgs; [
      radvd
    ] else [ ]);
    })
  ];
}

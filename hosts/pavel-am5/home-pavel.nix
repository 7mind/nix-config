{ pkgs, smind-hm, lib, extended_pkg, cfg-meta, inputs, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/git.nix"
    # cfg-inputs.agenix-rekey.homeManagerModules.default
  ];

  # age.rekey = {
  #   hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM1VvmTzQX/bvLjKEyDfGWdxGdt+3ZSy7/f6r5YAsvtS";
  #   # The path to the master identity used for decryption. See the option's description for more information.
  #   masterIdentities = [ ./your-yubikey-identity.pub ];
  #   #masterIdentities = [ "/home/myuser/master-key" ]; # External master key
  #   #masterIdentities = [
  #   #  # It is possible to specify an identity using the following alternate syntax,
  #   #  # this can be used to avoid unecessary prompts during encryption.
  #   #  {
  #   #    identity = "/home/myuser/master-key.age"; # Password protected external master key
  #   #    pubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq"; # Specify the public key explicitly
  #   #  }
  #   #];
  #   storageMode = "local";
  #   # Choose a directory to store the rekeyed secrets for this host.
  #   # This cannot be shared with other hosts. Please refer to this path
  #   # from your flake's root directory and not by a direct path literal like ./secrets
  #   localStorageDir = ./. + "/secrets/rekeyed/${config.networking.hostName}";
  # };

  smind.hm = {
    roles.desktop = true;
    firefox.sync-username = "pshirshov@gmail.com";
    autostart.programs = with pkgs; [
      {
        name = "element";
        exec = "${element-desktop}/bin/element-desktop --hidden";
      }
      {
        name = "slack";
        exec = "${slack}/bin/slack -u";
      }
      {
        name = "telegram-desktop";
        exec = "${pkgs.telegram-desktop}/bin/telegram-desktop -startintray";
      }
    ];
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  services.megasync.enable = true;
  services.megasync.package = (pkgs.megasync.overrideAttrs (drv:
    {
      buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
      preFixup = ''
        ${drv.preFixup}
         qtWrapperArgs+=(--set "QT_STYLE_OVERRIDE" "adwaita")
         qtWrapperArgs+=(--set "DO_NOT_UNSET_XDG_SESSION_TYPE" "1")
         qtWrapperArgs+=(--set "QT_SCALE_FACTOR" "1")
         qtWrapperArgs+=(--set "QT_QPA_PLATFORM" "xcb")
      '';
    }));

  home.packages = with pkgs; [
    element-desktop
    bitwarden-desktop

    visualvm

    vlc
    telegram-desktop


    (extended_pkg {
      pkg = jetbrains.idea-ultimate;
      path = "bin/idea-ultimate";
      ld-libs = [
        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        libGL
        icu
        fontconfig
        gccStdenv.cc.cc.lib
      ];
      #defs = { TEST = "1"; };
    })

    (extended_pkg {
      pkg = jetbrains.rider;
      path = "bin/rider";
      paths = [
        dotnet-sdk_9
      ];
      ld-libs = [
        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        libGL
        icu
        fontconfig
      ];
    })

    (extended_pkg rec {
      pkg = jetbrains.clion;
      path = "bin/clion";
      ld-libs = [
        libGL
        libglvnd
        libGLU
        qt6.full
        vulkan-headers
        boost

        libxkbcommon

        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        icu
        fontconfig
      ];
      defs = {
        CMAKE_LIBRARY_PATH = lib.makeLibraryPath ld-libs;
        CMAKE_INCLUDE_PATH = lib.makeIncludePath ld-libs;
        CMAKE_PREFIX_PATH = "${qt6.full}";
      };
    })
  ];

}


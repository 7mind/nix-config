{ cfg-const, config, lib, pkgs, xdg_associate, cfg-meta, outerConfig, ... }:

{
  options = {
    smind.hm.environment.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = outerConfig.smind.isDesktop;
      description = "";
    };

    smind.hm.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = outerConfig.smind.isDesktop;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.environment.sane-defaults.enable {
    manual = lib.mkIf config.smind.hm.environment.all-docs.enable {
      html.enable = true;
    };

    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };

    programs.starship = {
      enable = true;
      settings = {
        command_timeout = 300;
        scala.disabled = true;
        add_newline = true;
        character = {
          success_symbol = "[➜](bold green)";
          error_symbol = "[➜](bold red)";
        };
        directory = {
          truncation_length = 5;
          truncate_to_repo = false;
          truncation_symbol = "…/";
          before_repo_root_style = "(dimmed cyan)";
        };
      };
    };

    programs.tealdeer = {
      enable = true;
      # updateOnActivation = false;
      settings = { updates = { auto_update = true; }; };
    };



    home.shellAliases = cfg-const.universal-aliases // {
      "j" = "z"; # zoxide
    };

    home.packages = lib.mkIf cfg-meta.isLinux (with pkgs; [
      # productivity
      libreoffice-fresh

      # graphics
      imagemagick
      nomacs-qt6

      # video
      vlc
      mpv
    ]);

    # programs.chromium.enable = true;
    programs.librewolf.enable = lib.mkIf cfg-meta.isLinux true;

    xdg = lib.mkIf cfg-meta.isLinux (lib.mkMerge [
      {
        # mimeApps = {
        #   enable = true;
        #   associations = {
        #     added = {
        #       #"mimetype1" = [ "foo1.desktop" "foo2.desktop" "foo3.desktop" ];
        #     };
        #     removed = { };
        #   };
        # };
        userDirs = {
          enable = true;
          # see
          # https://github.com/nix-community/home-manager/blob/master/modules/misc/xdg-user-dirs.nix
        };
      }

      (xdg_associate {
        desktopfile = "org.nomacs.ImageLounge.desktop";
        schemes = [
          "image/jpeg"
          "image/png"
          "image/gif"
          "image/webp"
          "image/tiff"
          "image/x-tga"
          "image/vnd-ms.dds"
          "image/x-dds"
          "image/bmp"
          "image/vnd.microsoft.icon"
          "image/vnd.radiance"
          "image/x-exr"
          "image/x-portable-bitmap"
          "image/x-portable-graymap"
          "image/x-portable-pixmap"
          "image/x-portable-anymap"
          "image/x-qoi"
          "image/svg+xml"
          "image/svg+xml-compressed"
          "image/avif"
          "image/heic"
          "image/jxl"
          "image/heif"
          "image/x-eps"
          "image/x-ico"
          "image/x-xbitmap"
          "image/x-xpixmap"
        ];
      })

      (xdg_associate {
        desktopfile = "vlc.desktop";
        schemes = [
          "video/x-ogm+ogg"
          "video/ogg"
          "video/x-ogm"
          "video/x-theora+ogg"
          "video/x-theora"
          "video/x-ms-asf"
          "video/x-ms-asf-plugin"
          "video/x-ms-asx"
          "video/x-ms-wm"
          "video/x-ms-wmv"
          "video/x-ms-wmx"
          "video/x-ms-wvx"
          "video/x-msvideo"
          "video/divx"
          "video/msvideo"
          "video/vnd.divx"
          "video/avi"
          "video/x-avi"
          "video/vnd.rn-realvideo"
          "video/mp2t"
          "video/mpeg"
          "video/mpeg-system"
          "video/x-mpeg"
          "video/x-mpeg2"
          "video/x-mpeg-system"
          "video/mp4"
          "video/mp4v-es"
          "video/x-m4v"
          "video/quicktime"
          "video/x-matroska"
          "video/webm"
          "video/3gp"
          "video/3gpp"
          "video/3gpp2"
          "video/vnd.mpegurl"
          "video/dv"
          "video/x-anim"
          "video/x-nsv"
          "video/fli"
          "video/flv"
          "video/x-flc"
          "video/x-fli"
          "video/x-flv"
        ];
      })

      (xdg_associate {
        desktopfile = "vlc.desktop";
        schemes = [
          "audio/x-vorbis+ogg"
          "audio/ogg"
          "audio/vorbis"
          "audio/x-vorbis"
          "audio/x-speex"
          "audio/opus"
          "audio/flac"
          "audio/x-flac"
          "audio/x-ms-asf"
          "audio/x-ms-asx"
          "audio/x-ms-wax"
          "audio/x-ms-wma"
          "audio/x-pn-windows-acm"
          "audio/vnd.rn-realaudio"
          "audio/x-pn-realaudio"
          "audio/x-pn-realaudio-plugin"
          "audio/x-real-audio"
          "audio/x-realaudio"
          "audio/mpeg"
          "audio/mpg"
          "audio/mp1"
          "audio/mp2"
          "audio/mp3"
          "audio/x-mp1"
          "audio/x-mp2"
          "audio/x-mp3"
          "audio/x-mpeg"
          "audio/x-mpg"
          "audio/aac"
          "audio/m4a"
          "audio/mp4"
          "audio/x-m4a"
          "audio/x-aac"
          "audio/x-matroska"
          "audio/webm"
          "audio/3gpp"
          "audio/3gpp2"
          "audio/AMR"
          "audio/AMR-WB"
          "audio/mpegurl"
          "audio/x-mpegurl"
          "audio/scpls"
          "audio/x-scpls"
          "audio/dv"
          "audio/x-aiff"
          "audio/x-pn-aiff"
          "audio/wav"
          "audio/x-pn-au"
          "audio/x-pn-wav"
          "audio/x-wav"
          "audio/x-adpcm"
          "audio/ac3"
          "audio/eac3"
          "audio/vnd.dts"
          "audio/vnd.dts.hd"
          "audio/vnd.dolby.heaac.1"
          "audio/vnd.dolby.heaac.2"
          "audio/vnd.dolby.mlp"
          "audio/basic"
          "audio/midi"
          "audio/x-ape"
          "audio/x-gsm"
          "audio/x-musepack"
          "audio/x-tta"
          "audio/x-wavpack"
          "audio/x-shorten"
          "audio/x-it"
          "audio/x-mod"
          "audio/x-s3m"
          "audio/x-xm"
        ];
      })
    ]);

  };


}

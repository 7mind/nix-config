{ config, lib, pkgs, cfg-meta, extended_pkg, ... }:

let
  cfg = config.smind.hm.dev.jetbrains;

  commonPaths = [ pkgs.nodejs_24 pkgs.gcc ];

  commonLdLibs = with pkgs; [
    libmediainfo
    libx11
    libx11.dev
    libice
    libsm
    libGL
    icu
    fontconfig
    gccStdenv.cc.cc.lib
    zstd
  ];

  gsettingsSchemaDirs = with pkgs; [
    "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}"
    "${gtk3}/share/gsettings-schemas/${gtk3.name}"
    "${gtk4}/share/gsettings-schemas/${gtk4.name}"
  ];

  mkJetbrainsPackage = { pkg, path, extraPaths ? [ ], extraLdLibs ? [ ], defs ? (_: { }) }:
    let
      ldLibs = commonLdLibs ++ extraLdLibs;
    in
    extended_pkg {
      inherit pkg path;
      paths = commonPaths ++ extraPaths;
      ld-libs = ldLibs;
      defs = {
        XDG_DATA_DIRS = lib.concatStringsSep ":" gsettingsSchemaDirs;
      } // (defs ldLibs);
    };
in
{
  options = {
    smind.hm.dev.jetbrains.enable = lib.mkEnableOption "JetBrains IDEs with wrapper libraries";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg-meta.isLinux;
        message = "smind.hm.dev.jetbrains.enable is only supported on Linux.";
      }
    ];

    home.packages = [
      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.idea;
        path = "bin/idea";
      })

      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.webstorm;
        path = "bin/webstorm";
      })

      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.pycharm;
        path = "bin/pycharm";
      })

      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.datagrip;
        path = "bin/datagrip";
      })

      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.rider;
        path = "bin/rider";
        extraPaths = [ pkgs.dotnet-sdk_9 ];
      })

      (mkJetbrainsPackage {
        pkg = pkgs.jetbrains.clion;
        path = "bin/clion";
        extraLdLibs = with pkgs; [
          libGL
          libglvnd
          libGLU
          vulkan-headers
          boost
          libxkbcommon
        ];
        defs = ldLibs: {
          CMAKE_LIBRARY_PATH = lib.makeLibraryPath ldLibs;
          CMAKE_INCLUDE_PATH = lib.makeIncludePath ldLibs;
        };
      })
    ];
  };
}

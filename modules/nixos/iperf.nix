{ config, lib, pkgs, cfg-meta, ... }:

let
  user = "iperf-user";
in
{
  options = {
    smind.iperf.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.iperf.protected = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.iperf.enable {
    networking.firewall = {
      allowedTCPPorts = [
        5201 # iperf
      ];
      allowedUDPPorts = [
        5201 # iperf
      ];
    };

    environment.systemPackages = with pkgs; [
      iperf
      (writeShellScriptBin "iperfc" ''
        ${iperf}/bin/iperf -c --username "${user}" --rsa-public-key-path "${config.age.secrets.iperf-public-key.path}" $*
      '')
      # (pkgs.stdenvNoCC.mkDerivation {
      #     name = "iperfc";
      #     src = pkgs.writeText "iperfc" ''#!/usr/bin/env sh
      #     ${pkgs.iperf}/bin/iperf --username $user --rsa-public-key-path ${config.age.secrets.iperf-public-key.path}
      #     '';

      #     builder = pkgs.writeText "builder.sh" ''
      #       mkdir -p $out/bin
      #       cp $src $out/bin/$name
      #       chmod +x $out/bin/$name
      #     '';
      #   })
    ];

    age.secrets = {
      iperf-private-key = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/iperf-private-key.age";
        group = "users";
        mode = "444";
      };
      iperf-public-key = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/iperf-public-key.age";
        group = "users";
        mode = "444";
      };
      iperf-password = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/iperf-password.age";
        group = "users";
        mode = "444";
      };
    };

    # https://ittavern.com/iperf3-user-authentication-with-password-and-rsa-public-keypair/
    services.iperf3 = {
      enable = true;
      openFirewall = true;
      rsaPrivateKey = lib.mkIf config.smind.iperf.protected config.age.secrets.iperf-private-key.path;
      authorizedUsersFile = lib.mkIf config.smind.iperf.protected "/run/iperf-creds";
    };

    system.activationScripts."iperf-password" =
      ''
        secret=$(cat "${config.age.secrets.iperf-password.path}")
        sha=$(echo -n "{${user}}$secret" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{ print $1 }')
        echo "${user},$sha" > /run/iperf-creds
        chmod 444 /run/iperf-creds
      '';

  };
}

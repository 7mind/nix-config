{ config, lib, pkgs, cfg-meta, ... }:

let
  user = "iperf-user";
in
{
  options = {
    smind.iperf.enable = lib.mkEnableOption "iperf3 network performance testing";

    smind.iperf.protected.server.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable iperf3 server with authentication";
    };

    smind.iperf.protected.client.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable iperf3 client credentials";
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
    ] ++ (if (config.smind.age.active && config.smind.iperf.protected.client.enable) then [
      (writeShellScriptBin "iperfc" ''
        set -e
        export IPERF3_PASSWORD="$(cat '${config.age.secrets.iperf-password.path}')"
        set -x
        ${iperf}/bin/iperf --username "${user}" --rsa-public-key-path "${config.age.secrets.iperf-public-key.path}" -c $*
      '')
    ] else [ ]);

    # nix shell nixpkgs#openssl
    # mkdir ./tmp/
    # cd ./tmp/
    # openssl genrsa -des3 -out private.pem 2048
    # # Extract public key
    # openssl rsa -in private.pem -outform PEM -pubout -out public.pem
    # # Create unprotected private key for server
    # openssl rsa -in private.pem -out private_not_protected.pem -outform PEM
    # cd ..
    # cat ./tmp/public.pem | age -e -i ~/age-key.txt > ./private/secrets/generic/iperf-public-key.age
    # cat ./tmp/private_not_protected.pem | age -e -i ~/age-key.txt > ./private/secrets/generic/iperf-private-key.age

    age.secrets = lib.mkIf (config.smind.age.active && (config.smind.iperf.protected.server.enable || config.smind.iperf.protected.client.enable)) {
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
      rsaPrivateKey = lib.mkIf (config.smind.age.active && config.smind.iperf.protected.server.enable) config.age.secrets.iperf-private-key.path;
      authorizedUsersFile = lib.mkIf config.smind.iperf.protected.server.enable "/run/iperf-creds";
    };

    system.activationScripts."iperf-password" = lib.mkIf (config.smind.age.active && config.smind.iperf.protected.server.enable)
      ''
        secret=$(cat "${config.age.secrets.iperf-password.path}")
        sha=$(echo -n "{${user}}$secret" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{ print $1 }')
        echo "${user},$sha" > /run/iperf-creds
        chmod 444 /run/iperf-creds
      '';

  };
}

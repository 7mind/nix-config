# Builder function for AmneziaWG VPN containers.
# Import with the outer module args, then call with instance-specific params.

{ cfg-meta, mk_container, config, lib, pkgs }:

{ containerName, hostBridge, macAddress, dhcpHostname,
  awgPort, awgAddress,
  peersFile, secretsPrefix,
  privateUsersMultiplier,
  legacyHostPath ? "/srv/nixos-containers/${containerName}",
  dnsServers ? [ "1.1.1.1" "8.8.8.8" ],
  # Opt-in fixes for containers attached to the mikrotik LAN over a VXLAN
  # overlay. Defaults preserve behavior for direct-LAN deployments.
  mtuBytes ? null,            # null → kernel default (1500); set to 1450 over VXLAN
  requestBroadcast ? false,   # true → forces broadcast OFFER (RouterOS workaround)
  clientIdentifier ? null,    # "mac" → stable Client-ID across ephemeral recreates
  # Source-NAT VPN client traffic out of eth0. Default true preserves existing
  # behavior. Set to false when upstream routes the awg subnet directly to this
  # container's eth0 IP — that exposes per-peer source addresses to the rest of
  # the network (useful when downstream services need to distinguish peers).
  masquerade ? true,
}:

let
  awgInterface = "awg0";

  peersData = builtins.fromJSON (builtins.readFile peersFile);
  peers = map (p: p // { allowedIPs = "${p.ip}/32"; }) peersData.peers;
  ageEnabled = peersData.ageEnabled;
  awgParams = peersData.awgParams;
  awgEndpoint = peersData.awgEndpoint;

  vpnServerIp = lib.head (lib.splitString "/" awgAddress);

  containerRootUid = toString (65536 * privateUsersMultiplier);

  # Age secret definitions for all AWG keys
  awgSecrets = {
    "${secretsPrefix}-server-key" = {
      rekeyFile = "${cfg-meta.paths.secrets}/generic/${secretsPrefix}-server-key.age";
      owner = containerRootUid;
      mode = "0400";
    };
  } // lib.listToAttrs (lib.concatMap (peer: [
    {
      name = "${secretsPrefix}-key-${peer.name}";
      value = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/${secretsPrefix}-key-${peer.name}.age";
        owner = containerRootUid;
        mode = "0400";
      };
    }
    {
      name = "${secretsPrefix}-psk-${peer.name}";
      value = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/${secretsPrefix}-psk-${peer.name}.age";
        owner = containerRootUid;
        mode = "0400";
      };
    }
  ]) peers);

  # Bind mounts: age secrets as individual files, or legacy directory
  awgBindMountsAge = {
    "/var/lib/awg/server.key" = {
      hostPath = config.age.secrets."${secretsPrefix}-server-key".path;
      isReadOnly = true;
    };
  } // lib.listToAttrs (lib.concatMap (peer: [
    {
      name = "/var/lib/awg/key-${peer.name}";
      value = {
        hostPath = config.age.secrets."${secretsPrefix}-key-${peer.name}".path;
        isReadOnly = true;
      };
    }
    {
      name = "/var/lib/awg/psk-${peer.name}";
      value = {
        hostPath = config.age.secrets."${secretsPrefix}-psk-${peer.name}".path;
        isReadOnly = true;
      };
    }
  ]) peers);

  awgBindMountsLegacy = {
    "/var/lib/awg" = {
      hostPath = legacyHostPath;
      isReadOnly = false;
    };
  };
in
{
  age.secrets = lib.mkIf ageEnabled awgSecrets;

  containers.${containerName} = mk_container {
    ephemeral = true;
    inherit hostBridge;
    enableTun = true;
    inherit privateUsersMultiplier;

    bindMounts = if ageEnabled then awgBindMountsAge else awgBindMountsLegacy;

    config = { config, pkgs, lib, ... }:
      let
        peerConfigs = lib.concatMapStringsSep "\n" (peer: ''
          [Peer]
          PublicKey = ${peer.publicKey}
          PresharedKey = $(cat /var/lib/awg/psk-${peer.name})
          AllowedIPs = ${peer.allowedIPs}
        '') peers;

        generateConfig = pkgs.writeShellScript "awg-generate-config" ''
          set -euo pipefail

          umask 077
          mkdir -p /run/awg

          cat > /run/awg/${awgInterface}.conf <<CONF
          [Interface]
          PrivateKey = $(cat /var/lib/awg/server.key)
          Address = ${awgAddress}
          ListenPort = ${toString awgPort}
          PostUp = iptables -A FORWARD -i %i -j ACCEPT${lib.optionalString masquerade "; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"}
          PostDown = iptables -D FORWARD -i %i -j ACCEPT${lib.optionalString masquerade "; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"}
          Jc = ${toString awgParams.Jc}
          Jmin = ${toString awgParams.Jmin}
          Jmax = ${toString awgParams.Jmax}
          S1 = ${toString awgParams.S1}
          S2 = ${toString awgParams.S2}
          H1 = ${toString awgParams.H1}
          H2 = ${toString awgParams.H2}
          H3 = ${toString awgParams.H3}
          H4 = ${toString awgParams.H4}

          ${peerConfigs}
          CONF

          # strip leading whitespace from heredoc
          sed -i 's/^[[:space:]]*//' /run/awg/${awgInterface}.conf
        '';

        printClientConfig = let
          serverPubKeyCmd = "cat /var/lib/awg/server.key | awg pubkey";
          clientConfigTemplate = peer: ''
            echo "=========================================="
            echo "  ${peer.name} (${peer.allowedIPs})"
            echo "=========================================="
            PRIVKEY_FILE="/var/lib/awg/key-${peer.name}"
            PSK_FILE="/var/lib/awg/psk-${peer.name}"
            if [[ ! -f "$PRIVKEY_FILE" ]]; then
              echo "ERROR: missing private key file: $PRIVKEY_FILE" >&2
              exit 1
            fi
            if [[ ! -f "$PSK_FILE" ]]; then
              echo "ERROR: missing preshared key file: $PSK_FILE" >&2
              exit 1
            fi
            PRIVKEY="$(cat "$PRIVKEY_FILE")"
            PSK="$(cat "$PSK_FILE")"
            CONFIG="[Interface]
            PrivateKey = $PRIVKEY
            Address = ${peer.allowedIPs}
            DNS = ${vpnServerIp}
            Jc = ${toString awgParams.Jc}
            Jmin = ${toString awgParams.Jmin}
            Jmax = ${toString awgParams.Jmax}
            S1 = ${toString awgParams.S1}
            S2 = ${toString awgParams.S2}
            H1 = ${toString awgParams.H1}
            H2 = ${toString awgParams.H2}
            H3 = ${toString awgParams.H3}
            H4 = ${toString awgParams.H4}

            [Peer]
            PublicKey = $SERVER_PUB
            PresharedKey = $PSK
            Endpoint = ${awgEndpoint}
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25"
            CONFIG="$(echo "$CONFIG" | sed 's/^[[:space:]]*//')"
            echo "$CONFIG"
            echo ""
            echo "$CONFIG" | qrencode -t UTF8
            echo ""
          '';
        in pkgs.writeShellScript "awg-show-clients" ''
          set -euo pipefail
          export PATH="${lib.makeBinPath [ pkgs.amneziawg-tools pkgs.qrencode ]}:$PATH"

          SERVER_PUB="$(${serverPubKeyCmd})"

          ${lib.concatMapStringsSep "\n" clientConfigTemplate peers}
        '';
      in
      {
        systemd.network = {
          networks = {
            "10-eth0" = {
              name = "eth0";
              DHCP = "ipv4";
              linkConfig = { MACAddress = macAddress; }
                // lib.optionalAttrs (mtuBytes != null) { MTUBytes = toString mtuBytes; };
              networkConfig = {
                IPv6PrivacyExtensions = "no";
                DHCPPrefixDelegation = "no";
                IPv6AcceptRA = "no";
                LinkLocalAddressing = "no";
              };
              dhcpV4Config = {
                SendHostname = true;
                Hostname = dhcpHostname;
              }
                // lib.optionalAttrs requestBroadcast { RequestBroadcast = true; }
                // lib.optionalAttrs (clientIdentifier != null) { ClientIdentifier = clientIdentifier; };
            };
          };
        };

        networking.enableIPv6 = false;

        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
        };

        networking.firewall = {
          allowedUDPPorts = [ awgPort 53 ];
          allowedTCPPorts = [ 53 ];
        };

        services.dnsmasq = {
          enable = true;
          settings = {
            listen-address = "${vpnServerIp},127.0.0.1";
            bind-dynamic = true;
            no-resolv = true;
            server = dnsServers;
          };
        };

        systemd.services.dnsmasq = {
          after = [ "awg.service" ];
          wants = [ "awg.service" ];
        };

        environment.systemPackages = [
          pkgs.amneziawg-tools
          pkgs.amneziawg-go
          pkgs.qrencode
          (pkgs.writeShellScriptBin "awg-show-clients" ''
            exec ${printClientConfig}
          '')
        ];

        systemd.services.awg = {
          description = "AmneziaWG tunnel - ${awgInterface}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          path = with pkgs; [
            amneziawg-tools
            amneziawg-go
            iptables
            iproute2
          ];

          environment = {
            WG_QUICK_USERSPACE_IMPLEMENTATION = "amneziawg-go";
          };

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStartPre = generateConfig;
            ExecStart = "${pkgs.amneziawg-tools}/bin/awg-quick up /run/awg/${awgInterface}.conf";
            ExecStop = "${pkgs.amneziawg-tools}/bin/awg-quick down /run/awg/${awgInterface}.conf";
          };
        };
      };
  };
}

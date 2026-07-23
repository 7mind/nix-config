{ config, lib, pkgs, ... }:

# Asterisk PBX (PJSIP stack only; chan_sip no longer exists in Asterisk 22).
#
# Secrets never reach the Nix store: pjsip.conf lives in /etc/asterisk (world
# readable) and ends with an #include of a runtime-generated file that carries
# every `type=auth` section. That file is written by the pre-start hook from the
# agenix secret paths, mode 0640 asterisk:asterisk.
#
# The TLS transport is emitted into the same runtime file, and only when the
# certificate is actually present -- so a not-yet-issued ACME cert degrades to
# "no TLS listener" instead of taking the whole PBX down.
let
  cfg = config.smind.services.asterisk;

  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optionalString
    concatStringsSep
    concatMapStringsSep
    mapAttrsToList
    attrValues
    ;

  runtimeDir = "/run/asterisk";
  runtimeInclude = "${runtimeDir}/pjsip-runtime.conf";

  # Same NAT block on every transport. `local_net` suppresses the external
  # address rewrite for peers on these networks, so LAN devices (the ATA) are
  # unaffected by the internet-facing settings.
  natBlock = concatMapStringsSep "\n" (n: "local_net=${n}") cfg.nat.localNets
    + optionalString (cfg.nat.externalAddress != null) ''

      external_media_address=${cfg.nat.externalAddress}
      external_signaling_address=${cfg.nat.externalAddress}'';

  codecBlock = codecs: ''
    disallow=all
    allow=${concatStringsSep "," codecs}'';

  # A PJSIP transport serves exactly one address family, so dual-stack means a
  # second object bound to `::`. pjproject sets IPV6_V6ONLY, so this can reuse
  # the same port number without colliding with the IPv4 socket (verified).
  #
  # No NAT block here on purpose: IPv6 is end-to-end, so Asterisk's own address
  # is already the one peers must reach, and applying an IPv4 external address
  # to a v6 transport would corrupt the SDP.
  udp6Transport = optionalString cfg.ipv6.enable ''

    [${cfg.udpTransport}6]
    type=transport
    protocol=udp
    bind=[::]:${toString cfg.udpPort}
  '';

  extensionModule =
    { name, ... }:
    {
      options = {
        displayName = mkOption {
          type = types.str;
          default = name;
          description = "Caller ID name presented for this extension on internal calls.";
        };

        passwordFile = mkOption {
          type = types.path;
          description = ''
            File containing the SIP authentication password, read at service
            start. Never enters the Nix store.
          '';
        };

        codecs = mkOption {
          type = types.listOf types.str;
          default = cfg.codecs;
          description = "Offered codecs, most preferred first.";
        };

        maxContacts = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "How many devices may register this extension simultaneously.";
        };

        mediaEncryption = mkOption {
          type = types.enum [ "no" "sdes" "dtls" ];
          default = "no";
          description = "PJSIP media_encryption for this endpoint.";
        };

        mediaEncryptionOptimistic = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Fall back to unencrypted media when the peer does not offer SRTP.
            Set for endpoints that roam between LAN and internet.
          '';
        };
      };
    };

  extensions = cfg.extensions;

  endpointSections = concatStringsSep "\n" (mapAttrsToList
    (num: ext: ''
      [${num}]
      type=endpoint
      context=${cfg.dialplan.internalContext}
      ${codecBlock ext.codecs}
      auth=${num}
      aors=${num}
      callerid=${ext.displayName} <${num}>
      direct_media=no
      force_rport=yes
      rewrite_contact=yes
      rtp_symmetric=yes
      ice_support=no
      dtmf_mode=rfc4733
      media_encryption=${ext.mediaEncryption}
      media_encryption_optimistic=${if ext.mediaEncryptionOptimistic then "yes" else "no"}
      rtp_timeout=120
      rtp_timeout_hold=600

      [${num}]
      type=aor
      max_contacts=${toString ext.maxContacts}
      remove_existing=yes
      qualify_frequency=60
      qualify_timeout=5
    '')
    extensions);

  trunk = cfg.trunk;

  # In pjsip.conf `;` opens a comment, so URI parameters have to be escaped.
  trunkProxy = optionalString (trunk.proxy != null)
    "\noutbound_proxy=sip:${trunk.proxy}\\;lr";

  trunkTransportParam = optionalString (trunk.transport != "udp")
    "\\;transport=${trunk.transport}";

  # Outbound TLS needs a TLS transport object to originate from. It is kept
  # separate from the inbound listener on purpose: the listener only exists once
  # ACME has issued a certificate, and the trunk must not depend on that. A
  # client-role transport needs no certificate of its own.
  trunkTlsTransportName = "transport-trunk-tls";
  trunkNeedsTlsTransport = trunk.enable && trunk.transport == "tls";

  trunkTlsTransport = optionalString trunkNeedsTlsTransport ''
    [${trunkTlsTransportName}]
    type=transport
    protocol=tls
    bind=0.0.0.0:${toString trunk.tlsSourcePort}
    method=tlsv1_2
    ${natBlock}
  '';

  trunkTransportLine = optionalString trunkNeedsTlsTransport
    "\ntransport=${trunkTlsTransportName}";

  trunkSections = optionalString trunk.enable ''
    [${trunk.name}]
    type=endpoint
    context=${cfg.dialplan.trunkContext}
    ${codecBlock trunk.codecs}
    outbound_auth=${trunk.name}
    aors=${trunk.name}${trunkTransportLine}
    from_user=${trunk.username}
    from_domain=${trunk.domain}${trunkProxy}
    direct_media=no
    force_rport=yes
    rewrite_contact=yes
    rtp_symmetric=yes
    ice_support=no
    dtmf_mode=rfc4733
    rtp_timeout=120

    [${trunk.name}]
    type=aor
    contact=sip:${trunk.domain}${trunkTransportParam}${trunkProxy}
    qualify_frequency=60

    [${trunk.name}]
    type=registration${trunkTransportLine}
    outbound_auth=${trunk.name}
    server_uri=sip:${trunk.domain}${trunkTransportParam}
    client_uri=sip:${trunk.username}@${trunk.domain}
    contact_user=${trunk.username}${trunkProxy}
    retry_interval=60
    forbidden_retry_interval=600
    fatal_retry_interval=600
    expiration=${toString trunk.registrationExpiry}
    ; `line=yes` tags the Contact URI so inbound INVITEs are matched back to the
    ; endpoint by that tag. The provider fronts SIP on AWS, so its source
    ; addresses are not stable enough for a `type=identify` IP match.
    line=yes
    endpoint=${trunk.name}
  '';

  pjsipConf = ''
    ; Generated by smind.services.asterisk -- do not edit.

    [global]
    type=global
    user_agent=${cfg.userAgent}${optionalString (cfg.realm != null) ''

      ; Digest realm sent in WWW-Authenticate. Asterisk's default is the literal
      ; string "asterisk", which does not match the domain clients register
      ; against. Tolerant clients just echo whatever realm the server sends, but
      ; strict ones (Linphone) look up the stored password *by realm*, find
      ; nothing for "asterisk", and re-REGISTER with no Authorization header --
      ; producing an endless challenge loop with no InvalidPassword event.
      ; Setting this to the SIP domain makes those clients authenticate.
      default_realm=${cfg.realm}''}
    ; One SIP domain only; multi-domain matching is an attack surface here.
    disable_multi_domain=yes
    ; Emit a security event once this many unmatched requests arrive in the
    ; period below -- this is what the fail2ban jail keys on.
    unidentified_request_count=5
    unidentified_request_period=30
    unidentified_request_prune_interval=30

    [system]
    type=system
    timer_t1=500
    timer_b=32000

    [${cfg.udpTransport}]
    type=transport
    protocol=udp
    bind=0.0.0.0:${toString cfg.udpPort}
    ${natBlock}
    ${udp6Transport}
    ${trunkTlsTransport}
    ${endpointSections}
    ${trunkSections}

    ; type=auth sections and, when the certificate exists, the TLS transport.
    #include "${runtimeInclude}"
  '';

  ringTargets = concatStringsSep "&" (map (n: "PJSIP/${n}") cfg.dialplan.inboundRing);

  extensionsConf = ''
    ; Generated by smind.services.asterisk -- do not edit.

    [general]
    static=yes
    writeprotect=yes

    [${cfg.dialplan.internalContext}]
    ; Local extensions. An exact match always beats a pattern, so these win over
    ; the _X. catch-all below even though they also match it.
    ${concatStringsSep "\n" (mapAttrsToList
      (num: ext: ''
        exten => ${num},1,Dial(PJSIP/${num},${toString cfg.dialplan.ringTimeout})
         same => n,Hangup()'')
      extensions)}

    ; Loopback echo test -- the only way to judge the audio path end to end.
    exten => ${cfg.dialplan.echoTestExtension},1,Answer()
     same => n,Echo()
     same => n,Hangup()

    ${optionalString trunk.enable ''
      ; Everything else leaves via the trunk, normalised to E.164 without '+'.
      ; Irish national numbering: 00 = international prefix, leading 0 = national
      ; trunk code. Short codes (112/999) fall through unchanged.
      exten => _00X.,1,Goto(${cfg.dialplan.outboundContext},''${EXTEN:2},1)
      exten => _+X.,1,Goto(${cfg.dialplan.outboundContext},''${EXTEN:1},1)
      exten => _0X.,1,Goto(${cfg.dialplan.outboundContext},${trunk.nationalPrefix}''${EXTEN:1},1)
      exten => _X.,1,Goto(${cfg.dialplan.outboundContext},''${EXTEN},1)

      [${cfg.dialplan.outboundContext}]
      exten => _X.,1,NoOp(outbound ''${CALLERID(num)} -> ''${EXTEN})
       same => n,Set(CALLERID(num)=${trunk.callerId})
       same => n,Set(CALLERID(name)=${trunk.callerId})
       same => n,Dial(PJSIP/''${EXTEN}@${trunk.name},${toString cfg.dialplan.trunkTimeout})
       same => n,Hangup()

      [${cfg.dialplan.trunkContext}]
      ; Inbound DID: ring every listed extension at once. `s` is what Asterisk
      ; uses when the INVITE carries no dialable extension.
      exten => s,1,NoOp(inbound ''${CALLERID(all)} -> ''${EXTEN})
       same => n,Dial(${ringTargets},${toString cfg.dialplan.ringTimeout})
       same => n,Hangup()
      exten => _.,1,Goto(s,1)
    ''}
  '';

  rtpConf = ''
    [general]
    rtpstart=${toString cfg.rtpPortRange.from}
    rtpend=${toString cfg.rtpPortRange.to}
    icesupport=no
    strictrtp=yes
  '';

  loggerConf = ''
    [general]

    [logfiles]
    ; Goes to journald via syslog; the fail2ban jail reads it from there.
    ; `verbose` is included so that `pjsip set logger on` actually lands
    ; somewhere -- without it the SIP/SDP trace is emitted to nothing and call
    ; debugging is impossible without attaching a console. It only produces
    ; volume while a debug logger is switched on; journald handles rotation.
    syslog.local0 => notice,warning,error,security,verbose
  '';

  # Written at start-up so that secrets stay out of the Nix store.
  runtimeConfScript = pkgs.writeShellScript "asterisk-runtime-conf" ''
    set -euo pipefail
    umask 077
    install -d -o asterisk -g asterisk -m 0750 ${runtimeDir}

    tmp="${runtimeInclude}.tmp"
    : > "$tmp"

    emit_auth() {
      printf '[%s]\ntype=auth\nauth_type=userpass\nusername=%s\npassword=%s\n\n' \
        "$1" "$2" "$(cat "$3")" >> "$tmp"
    }

    ${concatStringsSep "\n" (mapAttrsToList
      (num: ext: ''emit_auth ${num} ${num} ${ext.passwordFile}'')
      extensions)}
    ${optionalString trunk.enable
      ''emit_auth ${trunk.name} ${trunk.authUser} ${trunk.passwordFile}''}

    ${optionalString (cfg.tls.certificateDir != null) ''
      cert="${cfg.tls.certificateDir}/${cfg.tls.certificateFile}"
      key="${cfg.tls.certificateDir}/${cfg.tls.keyFile}"
      if [ -r "$cert" ] && [ -r "$key" ]; then
        printf '%s\n' \
          '[${cfg.tlsTransport}]' \
          'type=transport' \
          'protocol=tls' \
          'bind=0.0.0.0:${toString cfg.tls.port}' \
          "cert_file=$cert" \
          "priv_key_file=$key" \
          'method=tlsv1_2' \
          ${lib.escapeShellArg natBlock} \
          >> "$tmp"
        ${optionalString cfg.ipv6.enable ''
          printf '\n%s\n' \
            '[${cfg.tlsTransport}6]' \
            'type=transport' \
            'protocol=tls' \
            'bind=[::]:${toString cfg.tls.port}' \
            "cert_file=$cert" \
            "priv_key_file=$key" \
            'method=tlsv1_2' \
            >> "$tmp"
        ''}
      else
        echo "asterisk: TLS certificate not readable at $cert -- starting without a TLS transport" >&2
      fi
    ''}

    chown asterisk:asterisk "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "${runtimeInclude}"
  '';
in
{
  options.smind.services.asterisk = {
    enable = mkEnableOption "Asterisk PBX";

    realm = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "pbx.example.org";
      description = ''
        Digest authentication realm advertised in challenges. Leave null to keep
        Asterisk's default (the literal string `asterisk`). Set it to the SIP
        domain clients register against: clients that match stored credentials
        by realm -- Linphone among them -- otherwise never send an Authorization
        header and loop on repeated challenges.
      '';
    };

    verboseLevel = mkOption {
      type = types.ints.unsigned;
      default = 3;
      description = ''
        Asterisk verbose level. Must be above 0 or every verbose message is
        discarded, including the `pjsip set logger on` SIP/SDP trace. Combined
        with `verbose` in logger.conf this makes call debugging a plain
        `journalctl -u asterisk`.
      '';
    };

    userAgent = mkOption {
      type = types.str;
      default = "PBX";
      description = "SIP User-Agent header. Deliberately uninformative.";
    };

    codecs = mkOption {
      type = types.listOf types.str;
      default = [ "opus" "g722" "alaw" "ulaw" ];
      description = ''
        Default codec preference for extensions. Opus first gives full-band
        audio (and its own FEC/PLC) between softphones; alaw/ulaw are the
        fallback the PSTN side is limited to anyway.
      '';
    };

    udpPort = mkOption {
      type = types.port;
      default = 5060;
      description = "UDP SIP port. Intended for the LAN only -- do not port-forward it.";
    };

    udpTransport = mkOption {
      type = types.str;
      default = "transport-udp";
      description = "PJSIP section name of the UDP transport.";
    };

    tlsTransport = mkOption {
      type = types.str;
      default = "transport-tls";
      description = "PJSIP section name of the TLS transport.";
    };

    rtpPortRange = {
      from = mkOption {
        type = types.port;
        default = 12000;
        description = "First RTP port.";
      };
      to = mkOption {
        type = types.port;
        default = 12200;
        description = "Last RTP port.";
      };
    };

    tls = {
      port = mkOption {
        type = types.port;
        default = 5061;
        description = ''
          TCP port for SIP over TLS. This is the only signalling port that
          should ever be reachable from the internet.
        '';
      };

      certificateDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Directory holding the TLS certificate and key. When null, or when the
          files are unreadable at start-up, no TLS transport is configured.
        '';
      };

      certificateFile = mkOption {
        type = types.str;
        default = "fullchain.pem";
        description = "Certificate file name inside certificateDir.";
      };

      keyFile = mkOption {
        type = types.str;
        default = "key.pem";
        description = "Private key file name inside certificateDir.";
      };
    };

    ipv6.enable = mkEnableOption ''
      dual-stack SIP: a second UDP transport, and a second TLS listener, bound
      to `::` on the same ports. IPv6 is end-to-end, so these carry no NAT
      settings -- clients reach the host directly and no port forward is
      involved, only an inbound allow rule on the router
    '';

    nat = {
      externalAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pbx.example.org";
        description = ''
          Public address advertised in SIP/SDP to peers outside `localNets`.
          Resolved once at start-up: restart Asterisk if the public IP changes.
        '';
      };

      localNets = mkOption {
        type = types.listOf types.str;
        default = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "100.64.0.0/10"
          "fd00::/8"
        ];
        description = "Networks treated as local, i.e. exempt from the NAT rewrite.";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the SIP and RTP ports in the host firewall.";
    };

    fail2ban = {
      enable = mkEnableOption "a fail2ban jail against SIP brute-force" // { default = true; };

      maxretry = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "Failures within findtime before a ban.";
      };

      findtime = mkOption {
        type = types.ints.positive;
        default = 600;
        description = "Sliding window in seconds.";
      };

      bantime = mkOption {
        type = types.ints.positive;
        default = 86400;
        description = "Ban duration in seconds.";
      };
    };

    extensions = mkOption {
      type = types.attrsOf (types.submodule extensionModule);
      default = { };
      description = "SIP extensions, keyed by extension number.";
    };

    trunk = {
      enable = mkEnableOption "an outbound SIP trunk";

      name = mkOption {
        type = types.str;
        default = "trunk";
        description = "PJSIP object name for the trunk.";
      };

      domain = mkOption {
        type = types.str;
        example = "sip.example.org";
        description = "SIP domain used in the trunk's From/To/Contact URIs.";
      };

      proxy = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "connect.example.org:5099";
        description = ''
          `host:port` every request is routed to, independent of `domain`.

          Normally unnecessary: PJSIP resolves `domain` per RFC 3263, so a
          provider publishing `_sip._udp.<domain>` SRV records is followed
          automatically. Set this only for providers whose media/signalling
          host cannot be discovered from `domain`.
        '';
      };

      transport = mkOption {
        type = types.enum [ "udp" "tcp" "tls" ];
        default = "udp";
        description = "Transport used towards the trunk.";
      };

      username = mkOption {
        type = types.str;
        description = "SIP user ID registered with the provider (usually the DID).";
      };

      authUser = mkOption {
        type = types.str;
        default = trunk.username;
        description = "Authentication user, when it differs from `username`.";
      };

      passwordFile = mkOption {
        type = types.path;
        description = "File containing the trunk password. Never enters the Nix store.";
      };

      callerId = mkOption {
        type = types.str;
        description = "Caller ID presented on outbound trunk calls.";
      };

      nationalPrefix = mkOption {
        type = types.str;
        example = "353";
        description = ''
          Country calling code substituted for a leading national trunk `0`
          when normalising dialled numbers to E.164.
        '';
      };

      tlsSourcePort = mkOption {
        type = types.port;
        default = 5062;
        description = ''
          Local port the trunk's client-side TLS transport binds to. Only
          relevant when `transport = "tls"`. Deliberately not opened in the
          firewall: it originates connections, it does not serve them.
        '';
      };

      registrationExpiry = mkOption {
        type = types.ints.positive;
        default = 600;
        description = "REGISTER expiry in seconds.";
      };

      codecs = mkOption {
        type = types.listOf types.str;
        default = [ "alaw" "ulaw" ];
        description = ''
          Trunk codecs. The PSTN side is 8 kHz G.711 regardless, so offering
          anything wider only invites needless transcoding.
        '';
      };
    };

    dialplan = {
      internalContext = mkOption {
        type = types.str;
        default = "internal";
        description = "Context the extensions dial in.";
      };

      outboundContext = mkOption {
        type = types.str;
        default = "outbound";
        description = "Context holding the normalised trunk dial.";
      };

      trunkContext = mkOption {
        type = types.str;
        default = "from-trunk";
        description = "Context inbound trunk calls land in.";
      };

      inboundRing = mkOption {
        type = types.listOf types.str;
        default = attrValues (lib.mapAttrs (n: _: n) cfg.extensions);
        defaultText = lib.literalExpression "all configured extensions";
        description = "Extensions rung simultaneously by an inbound trunk call.";
      };

      ringTimeout = mkOption {
        type = types.ints.positive;
        default = 45;
        description = "Seconds to ring an extension before giving up.";
      };

      trunkTimeout = mkOption {
        type = types.ints.positive;
        default = 90;
        description = "Seconds to wait for an outbound trunk call to be answered.";
      };

      echoTestExtension = mkOption {
        type = types.str;
        default = "600";
        description = "Extension that answers and echoes audio back, for path testing.";
      };
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      enable = true;
      confFiles = {
        "pjsip.conf" = pjsipConf;
        "extensions.conf" = extensionsConf;
        "rtp.conf" = rtpConf;
        "logger.conf" = loggerConf;
      };
      # Asterisk's verbose level defaults to 0, which silently discards every
      # verbose message -- including the entire `pjsip set logger on` SIP/SDP
      # trace, making call debugging impossible. Level 3 is the usual operational
      # setting: call progress plus, when enabled, full SIP messages.
      extraConfig = ''
        [options]
        verbose = ${toString cfg.verboseLevel}
      '';
    };

    systemd.services.asterisk = {
      # The upstream module writes preStart as `types.lines`, so this appends.
      # Upstream sets restartIfChanged=false to protect calls in progress, which
      # also means config changes need an explicit `systemctl restart asterisk`.
      preStart = lib.mkAfter "${runtimeConfScript}";

      # The upstream unit ships with zero sandboxing. These directives are the
      # subset that does NOT interfere with how Asterisk actually runs: it starts
      # as root, binds privileged ports (5060/5061), then drops to the asterisk
      # user, and uses realtime scheduling and AF_NETLINK for media/interface
      # work. So RestrictRealtime, RestrictAddressFamilies, SystemCallFilter and a
      # CapabilityBoundingSet are deliberately omitted here -- they need an on-box
      # start test before they can be trusted not to break RTP or the port bind.
      # ProtectSystem="full" keeps /usr,/boot,/etc read-only while leaving /var
      # and /run writable, which is all Asterisk needs.
      serviceConfig = {
        NoNewPrivileges = true;
        ProtectSystem = "full";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedUDPPorts = [ cfg.udpPort ];
      allowedTCPPorts = [ cfg.tls.port ];
      allowedUDPPortRanges = [
        { from = cfg.rtpPortRange.from; to = cfg.rtpPortRange.to; }
      ];
    };

    services.fail2ban = mkIf cfg.fail2ban.enable {
      enable = true;
      jails.asterisk.settings = {
        filter = "asterisk";
        backend = "systemd";
        journalmatch = "_SYSTEMD_UNIT=asterisk.service";
        maxretry = cfg.fail2ban.maxretry;
        findtime = cfg.fail2ban.findtime;
        bantime = cfg.fail2ban.bantime;
      };
    };

    assertions = [
      {
        assertion = cfg.rtpPortRange.from < cfg.rtpPortRange.to;
        message = "smind.services.asterisk.rtpPortRange.from must be below .to";
      }
      {
        assertion = !cfg.trunk.enable || cfg.extensions != { };
        message = "smind.services.asterisk.trunk requires at least one extension";
      }
      {
        assertion = lib.all (n: cfg.extensions ? ${n}) cfg.dialplan.inboundRing;
        message = "smind.services.asterisk.dialplan.inboundRing names an undefined extension";
      }
    ];
  };
}

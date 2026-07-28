{ pkgs }:

let
  testCertificate =
    pkgs.runCommand "flexisip-test-certificate"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir -p "$out"
        openssl req -x509 -newkey rsa:2048 -nodes \
          -subj /CN=pbx.test \
          -addext subjectAltName=DNS:pbx.test,DNS:lp.test \
          -days 1 \
          -keyout "$out/key.pem" \
          -out "$out/fullchain.pem"
      '';

  extensionPassword = pkgs.writeText "extension-101-password" "test-password";

  registeredCalleeScenario = pkgs.writeText "flexisip-registered-callee.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Register a persistent callee through Flexisip">
      <send retrans="500">
        <![CDATA[
          REGISTER sip:pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:101@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 REGISTER
          Contact: <sip:101@[local_ip]:[local_port]>
          Allow: INVITE, ACK, BYE, CANCEL, OPTIONS
          Max-Forwards: 70
          Expires: 60
          Supported: path
          Content-Length: 0
        ]]>
      </send>
      <recv response="401" auth="true"/>
      <send retrans="500">
        <![CDATA[
          REGISTER sip:pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:101@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 2 REGISTER
          Contact: <sip:101@[local_ip]:[local_port]>
          [authentication username=101 password=test-password]
          Allow: INVITE, ACK, BYE, CANCEL, OPTIONS
          Max-Forwards: 70
          Expires: 60
          Supported: path
          Content-Length: 0
        ]]>
      </send>
      <recv response="200"/>
      <pause milliseconds="120000"/>
    </scenario>
  '';

  registeredCalleeReceiveScenario = pkgs.writeText "flexisip-registered-callee-receive.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Answer calls to the registered callee">
      <recv request="INVITE"/>
      <send>
        <![CDATA[
          SIP/2.0 180 Ringing
          [last_Via:]
          [last_From:]
          [last_To:];tag=[pid]SIPpTag01[call_number]
          [last_Call-ID:]
          [last_CSeq:]
          Contact: <sip:101@[local_ip]:[local_port]>
          Content-Length: 0
        ]]>
      </send>
      <send retrans="500">
        <![CDATA[
          SIP/2.0 200 OK
          [last_Via:]
          [last_From:]
          [last_To:];tag=[pid]SIPpTag01[call_number]
          [last_Call-ID:]
          [last_CSeq:]
          Contact: <sip:101@[local_ip]:[local_port]>
          Content-Type: application/sdp
          Content-Length: [len]

          v=0
          o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
          s=-
          c=IN IP[media_ip_type] [media_ip]
          t=0 0
          m=audio [media_port] RTP/SAVP 8 0
          a=sendrecv
          a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
          a=rtpmap:8 PCMA/8000
          a=rtpmap:0 PCMU/8000
        ]]>
      </send>
      <recv request="ACK"/>
      <recv request="BYE"/>
      <send>
        <![CDATA[
          SIP/2.0 200 OK
          [last_Via:]
          [last_From:]
          [last_To:]
          [last_Call-ID:]
          [last_CSeq:]
          Contact: <sip:101@[local_ip]:[local_port]>
          Content-Length: 0
        ]]>
      </send>
    </scenario>
  '';

  conferenceCalleeReceiveScenario = pkgs.writeText "flexisip-conference-callee-receive.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Accept a conference-focus invitation">
      <recv request="INVITE"/>
      <send retrans="500">
        <![CDATA[
          SIP/2.0 200 OK
          [last_Via:]
          [last_From:]
          [last_To:];tag=[pid]SIPpTag01[call_number]
          [last_Call-ID:]
          [last_CSeq:]
          Contact: <sip:101@[local_ip]:[local_port]>
          Content-Length: 0
        ]]>
      </send>
      <recv request="ACK"/>
    </scenario>
  '';

  conferenceFocusInviteScenario = pkgs.writeText "flexisip-conference-focus-invite.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Invite a registered participant from the local conference focus">
      <send retrans="500">
        <![CDATA[
          INVITE sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:conference-focus@pbx.test;gr=urn:uuid:test-focus;conf-id=test-conference>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 INVITE
          Contact: <sip:conference-focus@pbx.test;gr=urn:uuid:test-focus;conf-id=test-conference>;isfocus;text
          Max-Forwards: 70
          Require: recipient-list-invite
          Content-Type: application/resource-lists+xml
          Content-Length: [len]

          <?xml version="1.0" encoding="UTF-8"?>
          <resource-lists xmlns="urn:ietf:params:xml:ns:resource-lists">
            <list><entry uri="sip:101@pbx.test"/></list>
          </resource-lists>
        ]]>
      </send>
      <recv response="100"/>
      <pause milliseconds="500"/>
    </scenario>
  '';

  spoofedConferenceFocusInviteScenario = pkgs.writeText "flexisip-spoofed-conference-focus-invite.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Reject a non-local conference-focus identity">
      <send retrans="500">
        <![CDATA[
          INVITE sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:conference-focus@pbx.test;gr=urn:uuid:spoofed-focus;conf-id=spoofed-conference>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 INVITE
          Contact: <sip:conference-focus@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <recv response="407"/>
      <send>
        <![CDATA[
          ACK sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:conference-focus@pbx.test;gr=urn:uuid:spoofed-focus;conf-id=spoofed-conference>;tag=[call_number]
          To: <sip:101@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 1 ACK
          Contact: <sip:conference-focus@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
    </scenario>
  '';

  extensionCallScenario = pkgs.writeText "asterisk-extension-call.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Authenticated extension call through Flexisip to a registered callee">
      <send retrans="500">
        <![CDATA[
          INVITE sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 INVITE
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Type: application/sdp
          Content-Length: [len]

          v=0
          o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
          s=-
          c=IN IP[media_ip_type] [media_ip]
          t=0 0
          m=audio [media_port] RTP/AVP 8 0
          a=sendrecv
          a=rtpmap:8 PCMA/8000
          a=rtpmap:0 PCMU/8000
        ]]>
      </send>
      <recv response="401" auth="true"/>
      <send>
        <![CDATA[
          ACK sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch-2]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 1 ACK
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <send retrans="500">
        <![CDATA[
          INVITE sip:101@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 2 INVITE
          Contact: <sip:103@[local_ip]:[local_port]>
          [authentication username=103 password=test-password]
          Max-Forwards: 70
          Content-Type: application/sdp
          Content-Length: [len]

          v=0
          o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
          s=-
          c=IN IP[media_ip_type] [media_ip]
          t=0 0
          m=audio [media_port] RTP/AVP 8 0
          a=sendrecv
          a=rtpmap:8 PCMA/8000
          a=rtpmap:0 PCMU/8000
        ]]>
      </send>
      <recv response="100" optional="true"/>
      <recv response="180" optional="true"/>
      <recv response="200" rrs="true"/>
      <send>
        <![CDATA[
          ACK [next_url] SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          [routes]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 2 ACK
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <pause milliseconds="500"/>
      <send retrans="500">
        <![CDATA[
          BYE [next_url] SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          [routes]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 3 BYE
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <recv response="200"/>
    </scenario>
  '';

  echoCallScenario = pkgs.writeText "flexisip-echo-call.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Authenticated call through Flexisip to Asterisk echo service">
      <send retrans="500">
        <![CDATA[
          INVITE sip:600@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:600@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 INVITE
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Subject: Flexisip echo routing test
          Content-Type: application/sdp
          Content-Length: [len]

          v=0
          o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
          s=-
          c=IN IP[media_ip_type] [media_ip]
          t=0 0
          m=audio [media_port] RTP/AVP 8
          a=rtcp:[media_port+1]
          a=sendrecv
          a=rtpmap:8 PCMA/8000
        ]]>
      </send>
      <recv response="401" auth="true"/>
      <send>
        <![CDATA[
          ACK sip:600@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch-2]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:600@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 1 ACK
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <send retrans="500">
        <![CDATA[
          INVITE sip:600@pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:600@pbx.test>
          Call-ID: [call_id]
          CSeq: 2 INVITE
          Contact: <sip:103@[local_ip]:[local_port]>
          [authentication username=103 password=test-password]
          Max-Forwards: 70
          Subject: Flexisip echo routing test
          Content-Type: application/sdp
          Content-Length: [len]

          v=0
          o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
          s=-
          c=IN IP[media_ip_type] [media_ip]
          t=0 0
          m=audio [media_port] RTP/AVP 8
          a=rtcp:[media_port+1]
          a=sendrecv
          a=rtpmap:8 PCMA/8000
        ]]>
      </send>
      <recv response="100" optional="true"/>
      <recv response="200" rrs="true"/>
      <send>
        <![CDATA[
          ACK [next_url] SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          [routes]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:600@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 2 ACK
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <nop>
        <action>
          <exec rtp_stream="apattern,1,8,PCMA/8000"/>
        </action>
      </nop>
      <pause milliseconds="1500"/>
      <nop>
        <action>
          <exec rtp_stream="pauseapattern"/>
        </action>
      </nop>
      <send retrans="500">
        <![CDATA[
          BYE [next_url] SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          [routes]
          From: <sip:103@pbx.test>;tag=[call_number]
          To: <sip:600@pbx.test>[peer_tag_param]
          Call-ID: [call_id]
          CSeq: 3 BYE
          Contact: <sip:103@[local_ip]:[local_port]>
          Max-Forwards: 70
          Content-Length: 0
        ]]>
      </send>
      <recv response="200" crlf="true"/>
      <ResponseTimeRepartition value="10,20,30,40,50,100,150,500,1000"/>
      <CallLengthRepartition value="10,50,100,500,1000,5000"/>
    </scenario>
  '';

in
pkgs.testers.runNixOSTest {
  name = "flexisip-file-transfer";

  nodes.server =
    { config, lib, ... }:
    {
      imports = [
        ../modules/nixos/asterisk.nix
        ../modules/nixos/flexisip.nix
      ];

      networking.hosts = {
        "127.0.0.1" = [ "lp.test" ];
        "192.0.2.1" = [ "pbx.test" ];
      };
      networking.interfaces.lo.ipv4.addresses = [
        {
          address = "192.0.2.1";
          prefixLength = 32;
        }
      ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.libxml2
        pkgs.sipsak
        pkgs.sipp
      ];

      smind.services.asterisk = {
        enable = true;
        realm = "pbx.test";
        openFirewall = false;
        fail2ban.enable = false;
        rtpPortRange = {
          from = 13000;
          to = 13200;
        };
        extensions."101" = {
          displayName = "test";
          passwordFile = extensionPassword;
          rewriteContact = false;
          mediaEncryption = "sdes";
          mediaEncryptionOptimistic = false;
        };
        extensions."103" = {
          displayName = "caller";
          passwordFile = extensionPassword;
        };
      };

      smind.services.flexisip = {
        enable = true;
        package = pkgs.callPackage ../pkg/flexisip/default.nix { };
        role = "frontend";
        domain = "pbx.test";
        bindAddress = "127.0.0.1";
        tls.certificateDir = testCertificate;
        authentication.enable = true;
        extensions."101" = {
          displayName = "test";
          passwordFile = extensionPassword;
        };
        preventMediaRelayLoops = false;
        rtpPortRange = {
          from = 12000;
          to = 12199;
        };
        messaging.database.enable = true;
        conference = {
          enable = true;
          package = pkgs.callPackage ../pkg/flexisip-conference/default.nix { };
          provisioningAccountIndex = 0;
        };
        presence.enable = true;
        push.enable = false;
        fileTransfer = {
          enable = true;
          package = pkgs.callPackage ../pkg/flexisip-http-file-transfer-server/default.nix { };
          publicHost = "lp.test";
          publicPort = 443;
          listenPort = 8443;
          maxFileSizeMiB = 1;
          retentionDays = 1;
        };
      };

      services.nginx = {
        enable = true;
        virtualHosts."lp.test" = {
          onlySSL = true;
          sslCertificate = "${testCertificate}/fullchain.pem";
          sslCertificateKey = "${testCertificate}/key.pem";
          locations."/".proxyPass = "https://127.0.0.1:8443";
          locations."/".extraConfig = ''
            proxy_http_version 1.1;
            proxy_request_buffering off;
            proxy_buffering off;
            proxy_hide_header Upgrade;
            proxy_set_header Authorization $http_authorization;
            proxy_set_header From $http_from;
            proxy_set_header Host pbx.test;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_ssl_server_name on;
            proxy_ssl_name pbx.test;
            proxy_ssl_verify on;
            proxy_ssl_verify_depth 1;
            proxy_ssl_trusted_certificate ${testCertificate}/fullchain.pem;
          '';
        };
      };

      assertions = [
        {
          assertion = !builtins.elem 8443 config.networking.firewall.allowedTCPPorts;
          message = "the Apache file-transfer backend must not be globally exposed";
        }
      ];

      # Let wait_for_unit report startup failures instead of observing the
      # production restart loop indefinitely.
      systemd.services.flexisip-proxy.serviceConfig.Restart = lib.mkForce "no";
      systemd.services.flexisip-conference.serviceConfig.Restart = lib.mkForce "no";
      systemd.services.flexisip-presence.serviceConfig.Restart = lib.mkForce "no";
    };

  testScript = ''
    start_all()
    server.wait_for_unit("mysql.service")
    server.wait_for_unit("asterisk.service")
    server.wait_for_unit("flexisip-database-prepare.service")
    server.wait_for_unit("flexisip-prepare.service")
    server.wait_for_unit("redis-flexisip.service")
    # Regression: Flexisip 2.6 must accept the generated configuration schema.
    server.wait_for_unit("flexisip-proxy.service")
    server.wait_for_unit("flexisip-conference.service")
    server.wait_for_unit("flexisip-presence.service")
    server.wait_for_unit("httpd.service")
    server.wait_for_unit("nginx.service")

    server.succeed("test $(systemctl show --property LimitNOFILE --value flexisip-proxy.service) -eq 524288")
    server.succeed("! grep -E '^(debug|tls-certificates-dir)=' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'auth-domains-mode=static' /run/flexisip/flexisip.conf")
    server.succeed("grep -A1 -F '[module::Authorization]' /run/flexisip/flexisip.conf | grep -Fx 'enabled=false'")
    server.succeed(
        "grep -Fx \"filter=is_request && (request.method-name == 'MESSAGE' || "
        "request.method-name == 'PUBLISH' || request.method-name == 'SUBSCRIBE' || "
        "(request.method-name == 'INVITE' && from.uri.user == 'conference-focus' && "
        "from.uri.domain == 'pbx.test'))\" "
        "/run/flexisip/flexisip.conf"
    )
    server.succeed("grep -Fx 'trusted-hosts=127.0.0.1' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'support-legacy-client=false' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'transports=sips:pbx.test:5061;maddr=127.0.0.1 sip:127.0.0.1:5070' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'sdp-port-range=12000-12199' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'prevent-loops=false' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'force-public-ip-for-sdp-masquerading=true' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'message-database-enabled=true' /run/flexisip/flexisip.conf")
    server.succeed(
        "grep -F \"filter=is_request && ((request.method-name == 'MESSAGE' && "
        "!(request.uri.user == 'conference-factory' || request.uri.user == 'conference-focus')) || "
        "(request.method-name == 'INVITE' && from.uri.user == 'conference-focus' && "
        "from.uri.domain == 'pbx.test'))\" "
        "/run/flexisip/flexisip.conf"
    )
    server.succeed("grep -F 'db-implementation=redis' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'redis-server-domain=127.0.0.1' /run/flexisip/flexisip.conf")
    server.succeed("grep -F 'redis-server-port=6379' /run/flexisip/flexisip.conf")
    server.succeed("! grep -F '__FLEXISIP_' /run/flexisip/flexisip.conf")
    server.succeed("! grep -F '__FLEXISIP_' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -Fx 'conference-factory-uris=sip:conference-factory@pbx.test' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -Fx 'conference-focus-uris=sip:conference-focus@pbx.test' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -Fx 'outbound-proxy=sip:127.0.0.1:5070;transport=tcp' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -Fx 'supported-media-types=text' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -Fx 'auth-domains-mode=static' /run/flexisip/flexisip-conference.conf")
    server.succeed("grep -F \"request.method-name == 'REGISTER'\" /run/flexisip/routes.conf")
    server.succeed(
        "test $(grep -n -F '<sip:127.0.0.1:6064;transport=tcp>' /run/flexisip/routes.conf | cut -d: -f1) "
        "-lt $(grep -n -F '<sip:127.0.0.1:5060;transport=udp>' /run/flexisip/routes.conf | cut -d: -f1)"
    )
    server.succeed("grep -A14 -F '[101]' /etc/asterisk/pjsip.conf | grep -Fx 'rewrite_contact=no'")
    server.succeed("grep -A14 -F '[103]' /etc/asterisk/pjsip.conf | grep -Fx 'rewrite_contact=yes'")
    server.succeed("test $(mariadb --protocol=socket --batch --skip-column-names -e 'SELECT COUNT(*) FROM flexisip_accounts.accounts') -eq 1")
    server.succeed("test $(mariadb --protocol=socket --batch --skip-column-names -e 'SELECT HEX(password) FROM flexisip_accounts.passwords') = 746573742D70617373776F7264")
    server.succeed("mariadb --protocol=socket --batch --skip-column-names -e 'USE flexisip_conference; SHOW TABLES' | grep -q .")
    server.succeed("redis-cli -p 6379 ping | grep -Fx PONG")
    server.succeed("redis-cli -p 6379 set persistence-test present | grep -Fx OK")
    server.succeed("systemctl restart redis-flexisip.service")
    server.wait_for_unit("redis-flexisip.service")
    server.succeed("redis-cli -p 6379 get persistence-test | grep -Fx present")
    server.succeed("systemctl restart flexisip-proxy.service flexisip-conference.service")
    server.wait_for_unit("flexisip-proxy.service")
    server.wait_for_unit("flexisip-conference.service")
    server.succeed(
        "systemd-run --unit=sipp-callee --collect --service-type=exec "
        "--working-directory=/tmp sipp 127.0.0.1:5070 -sf ${registeredCalleeScenario} "
        "-rxsf ${registeredCalleeReceiveScenario} "
        "-i 127.0.0.2 -p 5091 -m 1 -nd "
        "-trace_err -error_file /tmp/callee.errors "
        "-trace_msg -message_file /tmp/callee.messages"
    )
    server.wait_until_succeeds("asterisk -rx 'pjsip show aor 101' | grep -F 'sip:101@'", timeout=10)
    extension_status, extension_output = server.execute(
        "cd /tmp && sipp 127.0.0.1:5070 -sf ${extensionCallScenario} "
        "-i 127.0.0.3 -p 5092 -m 1 -nd -recv_timeout 5000 "
        "-trace_err -error_file /tmp/extension.errors "
        "-trace_msg -message_file /tmp/extension.messages"
    )
    if extension_status != 0:
        print(extension_output)
        print(server.succeed(
            "cat /tmp/extension.errors /tmp/extension.messages "
            "/tmp/callee.errors /tmp/callee.messages 2>/dev/null || true"
        ))
        print(server.succeed("journalctl -u sipp-callee --no-pager || true"))
        print(server.succeed("asterisk -rx 'pjsip show aor 101'"))
    assert extension_status == 0, extension_status
    server.succeed("grep -F 'INVITE sip:101@' /tmp/callee.messages")
    server.succeed("systemctl stop sipp-callee")
    server.succeed(
        "systemd-run --unit=sipp-conference-callee --collect --service-type=exec "
        "--working-directory=/tmp sipp 127.0.0.1:5070 -sf ${registeredCalleeScenario} "
        "-rxsf ${conferenceCalleeReceiveScenario} "
        "-t t1 -i 127.0.0.2 -p 5091 -m 1 -nd "
        "-trace_err -error_file /tmp/conference-callee.errors "
        "-trace_msg -message_file /tmp/conference-callee.messages"
    )
    server.wait_until_succeeds(
        "asterisk -rx 'pjsip show aor 101' | grep -F 'sip:101@127.0.0.2:5091'",
        timeout=10,
    )
    conference_status, conference_output = server.execute(
        "cd /tmp && sipp 127.0.0.1:5070 -sf ${conferenceFocusInviteScenario} "
        "-t t1 -i 127.0.0.1 -p 5093 -m 1 -nd -recv_timeout 5000 "
        "-trace_err -error_file /tmp/conference-focus.errors "
        "-trace_msg -message_file /tmp/conference-focus.messages"
    )
    if conference_status != 0:
        print(conference_output)
        print(server.succeed(
            "cat /tmp/conference-focus.errors /tmp/conference-focus.messages "
            "/tmp/conference-callee.errors /tmp/conference-callee.messages 2>/dev/null || true"
        ))
        print(server.succeed(
            "journalctl -u flexisip-proxy -u flexisip-conference "
            "-u asterisk -u sipp-conference-callee --no-pager || true"
        ))
    assert conference_status == 0, conference_status
    server.succeed("grep -F 'INVITE sip:101@127.0.0.2:5091' /tmp/conference-callee.messages")
    spoofed_focus_status, spoofed_focus_output = server.execute(
        "cd /tmp && sipp 127.0.0.1:5070 -sf ${spoofedConferenceFocusInviteScenario} "
        "-t t1 -i 127.0.0.4 -p 5094 -m 1 -nd -recv_timeout 5000 "
        "-trace_err -error_file /tmp/spoofed-conference-focus.errors "
        "-trace_msg -message_file /tmp/spoofed-conference-focus.messages"
    )
    if spoofed_focus_status != 0:
        print(spoofed_focus_output)
        print(server.succeed(
            "cat /tmp/spoofed-conference-focus.errors "
            "/tmp/spoofed-conference-focus.messages 2>/dev/null || true"
        ))
    assert spoofed_focus_status == 0, spoofed_focus_status
    server.succeed("grep -F 'SIP/2.0 407 Proxy Authentication Required' /tmp/spoofed-conference-focus.messages")
    server.succeed("systemctl stop sipp-conference-callee")
    echo_status, echo_output = server.execute(
        "cd /tmp && sipp 127.0.0.1:5070 -sf ${echoCallScenario} "
        "-i 127.0.0.2 -p 5090 -m 1 -nd "
        "-trace_err -error_file /tmp/echo.errors "
        "-trace_msg -message_file /tmp/echo.messages "
        "-trace_logs -log_file /tmp/echo.log -rtpcheck_debug"
    )
    if echo_status != 0:
        print(echo_output)
        print(server.succeed("cat /tmp/echo.errors /tmp/echo.log /tmp/debugafile /tmp/echo.messages 2>/dev/null || true"))
    assert echo_status == 0, echo_status
    server.succeed("grep -F 'c=IN IP4 192.0.2.1' /tmp/echo.messages")
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-config.xml "
        "| grep -F 'https://lp.test/flexisip-http-file-transfer-server/hft.php'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-config.xml "
        "| grep -F '<section name=\"proxy_default_values\">'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-config.xml "
        "| grep -F '<entry name=\"conference_factory_uri\" overwrite=\"true\">sip:conference-factory@pbx.test</entry>'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-config.xml "
        "| sed -n '/<section name=\"proxy_default_values\">/,/<\\/section>/p' "
        "| grep -F '<entry name=\"supported\" overwrite=\"true\">replaces, outbound, gruu, path, record-aware</entry>'"
    )
    server.succeed(
        "! curl --silent --show-error --insecure https://lp.test/linphone-config.xml "
        "| grep -F '<section name=\"proxy_0\">'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-conference-account-0.xml "
        "| grep -F '<entry name=\"transient_provisioning\" overwrite=\"true\">1</entry>'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-conference-account-0.xml "
        "| sed -n '/<section name=\"proxy_0\">/,/<\\/section>/p' "
        "| grep -F '<entry name=\"conference_factory_uri\" overwrite=\"true\">sip:conference-factory@pbx.test</entry>'"
    )
    server.succeed(
        "curl --silent --show-error --insecure https://lp.test/linphone-conference-account-0.xml "
        "| sed -n '/<section name=\"proxy_0\">/,/<\\/section>/p' "
        "| grep -F '<entry name=\"supported\" overwrite=\"true\">replaces, outbound, gruu, path, record-aware</entry>'"
    )

    unauthenticated_status = server.succeed(
        "curl --silent --insecure --output /dev/null --write-out '%{http_code}' "
        "https://lp.test/flexisip-http-file-transfer-server/hft.php"
    )
    assert unauthenticated_status == "401", unauthenticated_status

    server.succeed("printf 'photo-payload' > /tmp/photo.jpg")
    upload_status = server.succeed(
        "curl --silent --show-error --insecure --digest --user 101:test-password "
        "--header 'From: sip:101@pbx.test' "
        "--form 'File=@/tmp/photo.jpg;type=image/jpeg' "
        "https://lp.test/flexisip-http-file-transfer-server/hft.php "
        "--output /tmp/descriptor.xml --write-out '%{http_code}'"
    )
    assert upload_status == "200", upload_status + server.succeed(
        "cat /var/lib/flexisip-file-transfer/*.log /var/log/httpd/error_log 2>/dev/null || true"
    )
    server.succeed(
        "xmllint --xpath 'string(//*[local-name()=\"data\"]/@url)' "
        "/tmp/descriptor.xml > /tmp/download-url"
    )
    server.succeed(
        "curl --silent --show-error --insecure --digest --user 101:test-password "
        "--header 'From: sip:101@pbx.test' \"$(cat /tmp/download-url)\" "
        "--resolve pbx.test:443:127.0.0.1 "
        "> /tmp/downloaded.jpg"
    )
    server.succeed("cmp /tmp/photo.jpg /tmp/downloaded.jpg")

    server.succeed("dd if=/dev/zero of=/tmp/oversized.jpg bs=1M count=2 status=none")
    oversized_status = server.succeed(
        "curl --silent --insecure --digest --user 101:test-password "
        "--header 'From: sip:101@pbx.test' "
        "--form 'File=@/tmp/oversized.jpg;type=image/jpeg' "
        "--output /dev/null --write-out '%{http_code}' "
        "https://lp.test/flexisip-http-file-transfer-server/hft.php"
    )
    assert oversized_status == "400", oversized_status

    server.succeed("touch /var/lib/flexisip-file-transfer/current")
    server.succeed("touch -d '3 days ago' /var/lib/flexisip-file-transfer/expired")
    server.succeed("systemctl start flexisip-file-transfer-cleanup.service")
    server.succeed("test -e /var/lib/flexisip-file-transfer/current")
    server.succeed("test ! -e /var/lib/flexisip-file-transfer/expired")
  '';
}

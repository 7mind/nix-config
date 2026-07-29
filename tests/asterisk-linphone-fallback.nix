{ pkgs }:

let
  extensionPassword = pkgs.writeText "asterisk-test-extension-password" "extension-password";
  fallbackPassword = pkgs.writeText "asterisk-test-fallback-password" "fallback-password";

  registerScenario = pkgs.writeText "asterisk-fallback-register.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Accept the Asterisk fallback registration">
      <recv request="REGISTER"/>
      <send>
        <![CDATA[
          SIP/2.0 200 OK
          [last_Via:]
          [last_From:]
          [last_To:];tag=[pid]SIPpTag01[call_number]
          [last_Call-ID:]
          [last_CSeq:]
          [last_Contact:]
          Expires: 600
          Content-Length: 0
        ]]>
      </send>
    </scenario>
  '';

  inviteScenario = pkgs.writeText "asterisk-fallback-invite.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Reject one fallback INVITE after recording it">
      <recv request="INVITE"/>
      <send>
        <![CDATA[
          SIP/2.0 100 Trying
          [last_Via:]
          [last_From:]
          [last_To:]
          [last_Call-ID:]
          [last_CSeq:]
          Content-Length: 0
        ]]>
      </send>
      <send>
        <![CDATA[
          SIP/2.0 486 Busy Here
          [last_Via:]
          [last_From:]
          [last_To:];tag=[pid]SIPpTag02[call_number]
          [last_Call-ID:]
          [last_CSeq:]
          Content-Length: 0
        ]]>
      </send>
      <recv request="ACK"/>
    </scenario>
  '';

  primaryCalleeScenario = pkgs.writeText "asterisk-primary-callee.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Register the primary extension">
      <send retrans="500">
        <![CDATA[
          REGISTER sip:pbx.test SIP/2.0
          Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
          From: <sip:101@pbx.test>;tag=[call_number]
          To: <sip:101@pbx.test>
          Call-ID: [call_id]
          CSeq: 1 REGISTER
          Contact: <sip:101@[local_ip]:[local_port]>
          Max-Forwards: 70
          Expires: 60
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
          [authentication username=101 password=extension-password]
          Max-Forwards: 70
          Expires: 60
          Content-Length: 0
        ]]>
      </send>
      <recv response="200"/>
      <pause milliseconds="120000"/>
    </scenario>
  '';

  primaryCalleeReceiveScenario = pkgs.writeText "asterisk-primary-callee-receive.xml" ''
    <?xml version="1.0" encoding="ISO-8859-1" ?>
    <!DOCTYPE scenario SYSTEM "sipp.dtd">
    <scenario name="Answer the primary extension call">
      <recv request="INVITE"/>
      <send>
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
          m=audio [media_port] RTP/SAVP 8
          a=sendrecv
          a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
          a=rtpmap:8 PCMA/8000
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
in
pkgs.testers.runNixOSTest {
  name = "asterisk-linphone-fallback";

  nodes.server =
    { lib, ... }:
    {
      imports = [ ../modules/nixos/asterisk.nix ];

      environment.systemPackages = [
        pkgs.iproute2
        pkgs.sipp
      ];

      smind.services.asterisk = {
        enable = true;
        realm = "pbx.test";
        openFirewall = false;
        fail2ban.enable = false;

        extensions."101".passwordFile = extensionPassword;
        extensions."102".passwordFile = extensionPassword;

        linphoneFallback = {
          enable = true;
          domain = "127.0.0.2:5095";
          transport = "udp";
          username = "pbx-fallback";
          passwordFile = fallbackPassword;
          targets."101" = "mobile101";
          targets."102" = "mobile102";
          ringTimeout = 2;
        };
      };

      systemd.services.asterisk.wantedBy = lib.mkForce [ ];
    };

  nodes.tlsclient =
    { lib, ... }:
    {
      imports = [ ../modules/nixos/asterisk.nix ];

      smind.services.asterisk = {
        enable = true;
        realm = "pbx.test";
        openFirewall = false;
        fail2ban.enable = false;

        extensions."101".passwordFile = extensionPassword;

        linphoneFallback = {
          enable = true;
          domain = "sip.linphone.org";
          transport = "tls";
          username = "pbx-fallback";
          passwordFile = fallbackPassword;
          targets."101" = "mobile101";
        };
      };

      systemd.services.asterisk.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    start_all()
    server.wait_for_unit("multi-user.target")
    tlsclient.wait_for_unit("multi-user.target")
    tlsclient.succeed("grep -F '[transport-outbound-tls]' /etc/asterisk/pjsip.conf")
    tlsclient.succeed("grep -Fx 'protocol=tls' /etc/asterisk/pjsip.conf")
    tlsclient.succeed("grep -Fx 'verify_server=yes' /etc/asterisk/pjsip.conf")
    tlsclient.succeed("grep -Fx 'ca_list_file=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt' /etc/asterisk/pjsip.conf")
    tlsclient.succeed("grep -Fx 'transport=transport-outbound-tls' /etc/asterisk/pjsip.conf")
    tlsclient.fail("grep -F 'cert_file=' /etc/asterisk/pjsip.conf")
    server.succeed(
      "systemd-run --unit=fallback-register --service-type=exec --collect "
      "${pkgs.sipp}/bin/sipp -sf ${registerScenario} -i 127.0.0.2 -p 5095 "
      "-m 1 -nd -trace_err -error_file /tmp/fallback-register.errors "
      "-trace_msg -message_file /tmp/fallback-register.messages"
    )
    server.wait_until_succeeds("ss -lun | grep -F '127.0.0.2:5095'")
    server.succeed("systemctl start asterisk.service")
    server.wait_for_unit("asterisk.service")
    server.wait_until_succeeds("asterisk -rx 'core waitfullybooted'")

    server.succeed("grep -F '[linphone-fallback]' /etc/asterisk/pjsip.conf")
    server.succeed("grep -Fx 'username=pbx-fallback' /run/asterisk/pjsip-runtime.conf")
    server.succeed("grep -Fx 'password=fallback-password' /run/asterisk/pjsip-runtime.conf")
    server.fail("grep -F 'fallback-password' /etc/asterisk/pjsip.conf")
    server.succeed("grep -F 'DIALSTATUS' /etc/asterisk/extensions.conf | grep -F 'CHANUNAVAIL'")
    server.fail("grep -F 'DIALSTATUS' /etc/asterisk/extensions.conf | grep -F 'BUSY'")
    server.succeed("grep -F 'HANGUPCAUSE' /etc/asterisk/extensions.conf | grep -F '\"21\"'")
    server.succeed("grep -F 'Playback(beep&beep,noanswer)' /etc/asterisk/extensions.conf")
    server.succeed("grep -F '(linphone-fallback),Progress()' /etc/asterisk/extensions.conf")

    server.wait_until_succeeds(
      "asterisk -rx 'pjsip show registrations' | grep -E "
      "'linphone-fallback/sip:127[.]0[.]0[.]2:5095.*Registered'"
    )
    server.wait_until_succeeds("grep -F 'SIP/2.0 200 OK' /tmp/fallback-register.messages")
    server.wait_until_succeeds("! ss -lun | grep -F '127.0.0.2:5095'")

    server.succeed(
      "systemd-run --unit=fallback-invite --service-type=exec --collect "
      "${pkgs.sipp}/bin/sipp -sf ${inviteScenario} -i 127.0.0.2 -p 5095 "
      "-m 1 -nd -trace_err -error_file /tmp/fallback-invite.errors "
      "-trace_msg -message_file /tmp/fallback-invite.messages"
    )
    server.wait_until_succeeds("ss -lun | grep -F '127.0.0.2:5095'")
    server.succeed(
      "systemd-run --unit=primary-callee --collect --service-type=exec "
      "${pkgs.sipp}/bin/sipp 127.0.0.1:5060 -sf ${primaryCalleeScenario} "
      "-rxsf ${primaryCalleeReceiveScenario} -i 127.0.0.3 -p 5096 "
      "-m 1 -nd -trace_err -error_file /tmp/primary-callee.errors "
      "-trace_msg -message_file /tmp/primary-callee.messages"
    )
    server.wait_until_succeeds(
      "asterisk -rx 'pjsip show aor 101' | grep -F 'sip:101@127.0.0.3:5096'"
    )
    server.succeed("asterisk -rx 'channel originate Local/101@internal application Wait 1'")
    server.wait_until_succeeds("grep -F 'BYE sip:101@127.0.0.3:5096' /tmp/primary-callee.messages")
    server.fail("grep -F 'INVITE ' /tmp/fallback-invite.messages")

    server.succeed("asterisk -rx 'channel originate Local/102@internal application Wait 1'")
    server.wait_until_succeeds(
      "grep -F 'INVITE sip:mobile102@127.0.0.2:5095 SIP/2.0' "
      "/tmp/fallback-invite.messages"
    )
  '';
}

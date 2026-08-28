{
  config,
  lib,
  pkgs,
  ...
}:

# Flexisip as an edge SIP proxy in front of a PBX (Asterisk), or optionally
# as a standalone proxy+B2BUA (legacy experimental path).
#
# Recommended household layout (`role = "frontend"`):
#
#   Softphone --TLS:5061--> Flexisip --UDP--> Asterisk :5060
#   ATA       --UDP:5060-------------------> Asterisk
#   IrishVoip --TLS------------------------> Asterisk (trunk)
#
# Flexisip owns the internet-facing TLS listener, holds client connections
# (needed for Linphone mobile push), and uses `reg-on-response` so Asterisk
# remains the authoritative registrar and dialplan/trunk/recording engine.
#
# Call recording and echo stay on Asterisk. Flexisip does not replace them.
let
  cfg = config.smind.services.flexisip;

  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkMerge
    types
    optionalString
    concatMapStringsSep
    ;

  runtimeDir = "/run/flexisip";
  stateDir = "/var/lib/flexisip";
  conferenceStateDir = "${stateDir}/conference";
  databaseStateDir = "${stateDir}/database";
  databasePasswordPath = "${databaseStateDir}/password";
  fileTransferStateDir = "/var/lib/flexisip-file-transfer";
  fileTransferConfigPath = "${runtimeDir}/file-transfer.conf.php";
  fileTransferAuthority =
    cfg.fileTransfer.publicHost
    + optionalString (cfg.fileTransfer.publicPort != 443) ":${toString cfg.fileTransfer.publicPort}";
  fileTransferUrl = "https://${fileTransferAuthority}/flexisip-http-file-transfer-server/hft.php";
  confPath = "${runtimeDir}/flexisip.conf";
  conferenceConfPath = "${runtimeDir}/flexisip-conference.conf";
  routesPath = "${runtimeDir}/routes.conf";
  authDbPath = "${runtimeDir}/users.db";
  providersPath = "${runtimeDir}/sip-bridge-providers.json";
  databasePasswordPlaceholder = "__FLEXISIP_DATABASE_PASSWORD__";
  fileTransferNoncePlaceholder = "__FLEXISIP_FILE_TRANSFER_NONCE__";
  conferenceFactoryUri = "sip:${cfg.conference.factoryUser}@${cfg.domain}";
  conferenceFocusUri = "sip:${cfg.conference.focusUser}@${cfg.domain}";
  conferenceRequestFilter = "(request.uri.user == '${cfg.conference.factoryUser}' || request.uri.user == '${cfg.conference.focusUser}')";
  conferenceFocusInviteFilter = "(request.method-name == 'INVITE' && from.uri.user == '${cfg.conference.focusUser}' && from.uri.domain == '${cfg.domain}')";
  frontendAuthenticationFilter =
    "is_request && (request.method-name == 'MESSAGE' || request.method-name == 'PUBLISH' || request.method-name == 'SUBSCRIBE'"
    + optionalString cfg.conference.enable " || ${conferenceFocusInviteFilter}"
    + ")";
  linphoneSupportedTags = "replaces, outbound, gruu, path, record-aware";
  routerFilter =
    if cfg.conference.enable then
      "is_request && ((request.method-name == 'MESSAGE' && !${conferenceRequestFilter}) || ${conferenceFocusInviteFilter})"
    else
      "is_request && request.method-name == 'MESSAGE'";
  linphoneProvisioningFile = pkgs.writeText "linphone-flexisip.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
      <section name="misc">
        <entry name="file_transfer_server_url" overwrite="true">${fileTransferUrl}</entry>
      </section>
      ${optionalString cfg.conference.enable ''
        <section name="proxy_default_values">
          <entry name="conference_factory_uri" overwrite="true">${conferenceFactoryUri}</entry>
          <entry name="supported" overwrite="true">${linphoneSupportedTags}</entry>
        </section>
      ''}
    </config>
  '';
  linphoneConferenceAccountProvisioningPath = "/linphone-conference-account-${toString cfg.conference.provisioningAccountIndex}.xml";
  linphoneConferenceAccountProvisioningFile = pkgs.writeText "linphone-flexisip-conference-account.xml" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
      <section name="misc">
        <entry name="transient_provisioning" overwrite="true">1</entry>
      </section>
      <section name="proxy_${toString cfg.conference.provisioningAccountIndex}">
        <entry name="conference_factory_uri" overwrite="true">${conferenceFactoryUri}</entry>
        <entry name="supported" overwrite="true">${linphoneSupportedTags}</entry>
      </section>
    </config>
  '';

  isFrontend = cfg.role == "frontend";
  isStandalone = cfg.role == "standalone";
  databaseEnabled = cfg.messaging.database.enable || cfg.fileTransfer.enable || cfg.conference.enable;

  extensionModule =
    { name, ... }:
    {
      options = {
        displayName = mkOption {
          type = types.str;
          default = name;
          description = "Display name for this extension.";
        };
        passwordFile = mkOption {
          type = types.path;
          description = "File containing the SIP authentication password (agenix).";
        };
      };
    };

  tlsTransportLine = optionalString (
    cfg.tls.certificateDir != null
  ) "sips:${cfg.domain}:${toString cfg.tls.port};maddr=${cfg.bindAddress}";

  # Frontend: TLS public + localhost UDP for hairpin. Do not bind a public UDP
  # SIP port (Asterisk already owns LAN :5060 for the ATA).
  # Standalone: classic sip:bind:udpPort + optional TLS.
  transports = lib.concatStringsSep " " (
    lib.filter (s: s != "") (
      (
        if isFrontend then
          [
            tlsTransportLine
            "sip:127.0.0.1:${toString cfg.internalUdpPort}"
          ]
        else
          [
            "sip:${cfg.bindAddress}:${toString cfg.udpPort}"
            tlsTransportLine
          ]
      )
      ++ cfg.extraTransports
    )
  );

  # Forward registrations and call signalling to Asterisk. Do NOT forward MESSAGE / presence
  # (SUBSCRIBE/PUBLISH/NOTIFY) — those stay on Flexisip (Router late-fork +
  # presence server). Registrar reg-on-response still records contacts from
  # Asterisk's 200 OK for delivery and connection reuse.
  routesConf = optionalString isFrontend ''
    ${optionalString cfg.conference.enable ''
      <sip:127.0.0.1:${toString cfg.conference.port};transport=tcp>    request.uri.domain == '${cfg.domain}' && ${conferenceRequestFilter}
    ''}
    <${cfg.backend.uri}>    request.uri.domain == '${cfg.domain}' && (request.method-name == 'REGISTER' || request.method-name == 'INVITE' || request.method-name == 'ACK' || request.method-name == 'CANCEL' || request.method-name == 'BYE' || request.method-name == 'UPDATE' || request.method-name == 'PRACK' || request.method-name == 'INFO' || request.method-name == 'REFER')
  '';

  writeAuthDb = pkgs.writeShellScript "flexisip-write-authdb" (
    if cfg.authentication.enable then
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        tmp=$(mktemp ${runtimeDir}/users.db.XXXXXX)
        {
          echo 'version:1'
      ''
      + concatMapStringsSep "\n" (
        name:
        let
          ext = cfg.extensions.${name};
        in
        ''
          pw=$(tr -d '\n' < ${lib.escapeShellArg ext.passwordFile})
          printf '%s@%s clrtxt:%s ;\n' ${lib.escapeShellArg name} ${lib.escapeShellArg cfg.domain} "$pw"
        ''
      ) (lib.attrNames cfg.extensions)
      + ''
        } > "$tmp"
        chown flexisip:flexisip "$tmp"
        chmod 0640 "$tmp"
        mv -f "$tmp" ${authDbPath}
      ''
    else
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        : > ${authDbPath}
        chown flexisip:flexisip ${authDbPath}
        chmod 0640 ${authDbPath}
      ''
  );

  providersTemplate = builtins.toJSON (
    if isStandalone && cfg.trunk.enable then
      {
        schemaVersion = 2;
        providers = [
          {
            name = "outbound-trunk";
            triggerCondition = {
              strategy = "MatchRegex";
              pattern = "^(?!1[0-9]{2}$).+";
              source = "{requestUri}";
            };
            accountToUse.strategy = "Random";
            onAccountNotFound = "decline";
            outgoingInvite = {
              to = "sip:{incoming.requestUri.user}@${cfg.trunk.domain}{incoming.requestUri.uriParameters}";
              from = "sip:${cfg.trunk.username}@${cfg.trunk.domain}";
              mediaEncryption = "none";
            };
            accountPool = "trunk";
          }
          {
            name = "inbound-trunk";
            triggerCondition.strategy = "Always";
            accountToUse = {
              strategy = "FindInPool";
              by = "uri";
              source = "{to}";
            };
            onAccountNotFound = "nextProvider";
            outgoingInvite = {
              to = "sip:${cfg.dialplan.inboundAlias}@${cfg.domain}";
              from = "{incoming.from}";
              outboundProxy = "sip:127.0.0.1:${toString cfg.udpPort};transport=udp";
            };
            accountPool = "trunk";
          }
        ];
        accountPools.trunk = {
          outboundProxy = "sips:${cfg.trunk.domain};transport=tls";
          registrationRequired = true;
          maxCallsPerLine = 4;
          loader = [
            {
              uri = "sip:${cfg.trunk.username}@${cfg.trunk.domain}";
              userid = cfg.trunk.username;
              secretType = "clrtxt";
              secret = "__TRUNK_PASSWORD__";
              alias = "sip:${cfg.dialplan.inboundAlias}@${cfg.domain}";
              protocol = "tls";
            }
          ];
        };
      }
    else
      {
        schemaVersion = 2;
        providers = [ ];
        accountPools = { };
      }
  );

  providersTemplateFile = pkgs.writeText "flexisip-providers.template.json" providersTemplate;

  writeProviders = pkgs.writeShellScript "flexisip-write-providers" (
    if isStandalone && cfg.trunk.enable then
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        tmp=$(mktemp ${runtimeDir}/providers.json.XXXXXX)
        pw=$(tr -d '\n' < ${lib.escapeShellArg cfg.trunk.passwordFile})
        ${pkgs.jq}/bin/jq --arg pw "$pw" \
          '(.accountPools.trunk.loader[0].secret) = $pw' \
          ${providersTemplateFile} > "$tmp"
        chown flexisip:flexisip "$tmp"
        chmod 0640 "$tmp"
        mv -f "$tmp" ${providersPath}
      ''
    else
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        cp ${providersTemplateFile} ${providersPath}
        chown flexisip:flexisip ${providersPath}
        chmod 0640 ${providersPath}
      ''
  );

  flexisipConfTemplate = pkgs.writeText "flexisip.conf.template" ''
    [global]
    log-level=message
    syslog-level=error
    log-directory=/var/log/flexisip
    transports=${transports}
    aliases=${cfg.domain}
    ${optionalString (cfg.tls.certificateDir != null) ''
      tls-certificates-file=${cfg.tls.certificateDir}/fullchain.pem
      tls-certificates-private-key=${cfg.tls.certificateDir}/key.pem
    ''}

    [module::DoSProtection]
    enabled=true

    [module::Authentication]
    enabled=${if cfg.authentication.enable then "true" else "false"}
    ${optionalString cfg.authentication.enable ''
      # In frontend mode Asterisk authenticates PBX-bound requests. If Flexisip
      # authenticates them first, it removes their credentials before forwarding.
      ${optionalString isFrontend "filter=${frontendAuthenticationFilter}"}
      ${optionalString (isFrontend && cfg.conference.enable) "trusted-hosts=127.0.0.1"}
      auth-domains=${cfg.domain}
      realm=${if cfg.realm != null then cfg.realm else cfg.domain}
      db-implementation=file
      file-path=${authDbPath}
      available-algorithms=MD5 SHA-256
      no-403=false
    ''}

    # Flexisip 2.6 returns 500 here when digest authentication succeeds but no
    # asserted-identity authorization scheme, such as OpenID Connect, is registered.
    [module::Authorization]
    enabled=false
    auth-domains-mode=static
    auth-domains=${cfg.domain}

    [module::Registrar]
    enabled=true
    reg-domains=${cfg.domain}
    max-contacts-by-aor=8
    db-implementation=${if cfg.conference.enable then "redis" else "internal"}
    ${optionalString cfg.conference.enable ''
      redis-server-domain=127.0.0.1
      redis-server-port=${toString cfg.conference.redisPort}
    ''}
    # Frontend: Asterisk accepts/rejects REGISTER; Flexisip holds the client
    # connection and records the contact from the 200 OK (Linphone push path).
    reg-on-response=${if isFrontend then "true" else "false"}

    [module::MediaRelay]
    enabled=${if cfg.mediaRelay then "true" else "false"}
    sdp-port-range=${toString cfg.rtpPortRange.from}-${toString cfg.rtpPortRange.to}
    prevent-loops=${if cfg.preventMediaRelayLoops then "true" else "false"}
    force-public-ip-for-sdp-masquerading=${if cfg.forcePublicMediaAddress then "true" else "false"}

    [module::Transcoder]
    enabled=${if cfg.transcoder then "true" else "false"}

    [module::Router]
    enabled=true
    ${optionalString isFrontend "filter=${routerFilter}"}
    call-fork-timeout=${toString cfg.dialplan.ringTimeout}
    call-fork-current-branches-timeout=${toString cfg.dialplan.ringTimeout}
    # 1:1 SIP MESSAGE: keep for late registrants, with an optional durable
    # MariaDB queue.
    message-fork-late=${if cfg.messaging.enable then "true" else "false"}
    message-delivery-timeout=${toString cfg.messaging.deliveryTimeoutSeconds}
    message-accept-timeout=${toString cfg.messaging.acceptTimeoutSeconds}
    message-database-enabled=${if cfg.messaging.database.enable then "true" else "false"}
    ${optionalString cfg.messaging.database.enable ''
      message-database-backend=mysql
      message-database-connection-string=db='flexisip_messages' user='flexisip' password='${databasePasswordPlaceholder}' host='127.0.0.1'
    ''}

    [module::Presence]
    enabled=${if cfg.presence.enable then "true" else "false"}
    ${optionalString cfg.presence.enable ''
      presence-server=sip:127.0.0.1:${toString cfg.presence.port};transport=tcp
    ''}

    [module::PushNotification]
    enabled=${if cfg.push.enable then "true" else "false"}
    timeout=0

    [presence-server]
    support-legacy-client=false
    ${optionalString cfg.presence.enable ''
      enabled=true
      transports=sip:127.0.0.1:${toString cfg.presence.port};transport=tcp
      expires=${toString cfg.presence.publishExpiresSeconds}
      # No long-term presence DB — in-memory PUBLISH only (enough for online/
      # offline among registered household Linphones).
      long-term-enabled=false
    ''}

    [module::B2bua]
    enabled=${if isStandalone && cfg.trunk.enable then "true" else "false"}
    ${optionalString (isStandalone && cfg.trunk.enable) ''
      b2bua-server=sip:127.0.0.1:${toString cfg.b2bua.port};transport=tcp
      filter=is_request && (request.method-name == 'INVITE' || request.method-name == 'CANCEL' || request.method-name == 'BYE' || request.method-name == 'ACK') && !(request.uri.user regex '1[0-9]{2}')
    ''}

    [module::Forward]
    enabled=true
    ${optionalString isFrontend "routes-config-path=${routesPath}"}
    add-path=true
    default-transport=udp

    ${optionalString (isStandalone && cfg.trunk.enable) ''
      [b2bua-server]
      application=sip-bridge
      transport=sip:127.0.0.1:${toString cfg.b2bua.port};transport=tcp
      data-directory=${stateDir}/b2b
      outbound-proxy=sip:127.0.0.1:${toString cfg.udpPort};transport=udp
      ${optionalString (cfg.nat.externalMediaAddress != null) ''
        nat-addresses=${cfg.nat.externalMediaAddress}
        enable-ice=true
      ''}

      [b2bua-server::sip-bridge]
      providers=${providersPath}
    ''}
  '';

  conferenceConfTemplate = pkgs.writeText "flexisip-conference.conf.template" ''
    [global]
    log-level=message
    syslog-level=error
    log-directory=/var/log/flexisip

    [conference-server]
    transport=sip:127.0.0.1:${toString cfg.conference.port};transport=tcp
    conference-factory-uris=${conferenceFactoryUri}
    conference-focus-uris=${conferenceFocusUri}
    outbound-proxy=sip:127.0.0.1:${toString cfg.internalUdpPort};transport=tcp
    local-domains=${cfg.domain}
    database-backend=mysql
    database-connection-string=db='flexisip_conference' user='flexisip' password='${databasePasswordPlaceholder}' host='127.0.0.1'
    check-capabilities=true
    supported-media-types=text
    state-directory=${conferenceStateDir}

    [module::Authorization]
    auth-domains-mode=static
    auth-domains=${cfg.domain}

    [module::Registrar]
    enabled=true
    reg-domains=${cfg.domain}
    db-implementation=redis
    redis-server-domain=127.0.0.1
    redis-server-port=${toString cfg.conference.redisPort}
  '';

  fileTransferConfigTemplate = pkgs.writeText "flexisip-file-transfer.conf.php.template" ''
    <?php
    define("fhft_tmp_path", ${builtins.toJSON "${fileTransferStateDir}/"});
    define("fhft_extension_black_list", ["html", "htm", "xhtml", "xht", "asp", "aspx", "php", "php3", "php4", "php5", "phtml", "jsp", "js", "lua", "cgi", "pl", "py", "pyc", "pyo", "rb", "tcl"]);
    define("fhft_extension_fallback", "txt");
    define("fhft_validity_period", ${toString (cfg.fileTransfer.retentionDays * 24 * 60 * 60)});
    define("fhft_maximum_file_size_in_MB", ${toString cfg.fileTransfer.maxFileSizeMiB});
    define("fhft_logLevel", LogLevel::ERROR);
    define("fhft_logFile", ${builtins.toJSON "${fileTransferStateDir}/server.log"});
    define("fhft_logDomain", "FHFT");
    define("DIGEST_AUTH", true);
    define("AUTH_DB_HOST", "127.0.0.1");
    define("AUTH_DB_USER", "flexisip");
    define("AUTH_DB_PASSWORD", "${databasePasswordPlaceholder}");
    define("AUTH_DB_NAME", "flexisip_accounts");
    define("ACCOUNTS_DB_TABLE", "accounts");
    define("ACCOUNTS_ALGO_DB_TABLE", "passwords");
    define("USE_PERSISTENT_CONNECTIONS", false);
    define("AUTH_REALM", ${builtins.toJSON cfg.domain});
    define("AUTH_QUERY", "SELECT password, algorithm FROM " . ACCOUNTS_ALGO_DB_TABLE . " WHERE account_id=(SELECT id FROM " . ACCOUNTS_DB_TABLE . " WHERE username=? AND domain=? LIMIT 1);");
    define("AUTH_NONCE_KEY", "${fileTransferNoncePlaceholder}");
    define("MIN_NONCE_VALIDITY_PERIOD", 10);
    ?>
  '';

  extensionAccountSql = concatMapStringsSep "\n" (
    name:
    let
      ext = cfg.extensions.${name};
    in
    ''
      username_hex=$(printf '%s' ${lib.escapeShellArg name} | ${pkgs.coreutils}/bin/od -An -v -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n')
      password_hex=$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg ext.passwordFile} | ${pkgs.coreutils}/bin/od -An -v -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n')
      ${pkgs.mariadb}/bin/mariadb --protocol=socket flexisip_accounts <<SQL
      INSERT INTO accounts (username, domain)
        VALUES (CONVERT(UNHEX('$username_hex') USING utf8mb4), CONVERT(UNHEX('$domain_hex') USING utf8mb4));
      SET @account_id = LAST_INSERT_ID();
      INSERT INTO passwords (account_id, password, algorithm)
        VALUES (@account_id, CONVERT(UNHEX('$password_hex') USING utf8mb4), 'CLRTXT');
      SQL
    ''
  ) (lib.attrNames cfg.extensions);

  prepareDatabase = pkgs.writeShellScript "flexisip-prepare-database" ''
    set -euo pipefail
    install -d -o root -g flexisip -m 0750 ${databaseStateDir}

    if [[ ! -s ${databasePasswordPath} ]]; then
      ${pkgs.coreutils}/bin/od -An -N32 -v -tx1 /dev/urandom \
        | ${pkgs.coreutils}/bin/tr -d ' \n' > ${databasePasswordPath}.tmp
      chown root:flexisip ${databasePasswordPath}.tmp
      chmod 0640 ${databasePasswordPath}.tmp
      mv ${databasePasswordPath}.tmp ${databasePasswordPath}
    fi

    if [[ ! -s ${databaseStateDir}/file-transfer-nonce ]]; then
      ${pkgs.coreutils}/bin/od -An -N32 -v -tx1 /dev/urandom \
        | ${pkgs.coreutils}/bin/tr -d ' \n' > ${databaseStateDir}/file-transfer-nonce.tmp
      chown root:flexisip ${databaseStateDir}/file-transfer-nonce.tmp
      chmod 0640 ${databaseStateDir}/file-transfer-nonce.tmp
      mv ${databaseStateDir}/file-transfer-nonce.tmp ${databaseStateDir}/file-transfer-nonce
    fi

    database_password=$(<${databasePasswordPath})
    ${pkgs.mariadb}/bin/mariadb --protocol=socket <<SQL
    CREATE DATABASE IF NOT EXISTS flexisip_messages CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS flexisip_accounts CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    ${optionalString cfg.conference.enable "CREATE DATABASE IF NOT EXISTS flexisip_conference CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"}
    CREATE USER IF NOT EXISTS 'flexisip'@'127.0.0.1' IDENTIFIED BY '$database_password';
    ALTER USER 'flexisip'@'127.0.0.1' IDENTIFIED BY '$database_password';
    GRANT ALL PRIVILEGES ON flexisip_messages.* TO 'flexisip'@'127.0.0.1';
    ${optionalString cfg.conference.enable "GRANT ALL PRIVILEGES ON flexisip_conference.* TO 'flexisip'@'127.0.0.1';"}
    GRANT SELECT ON flexisip_accounts.* TO 'flexisip'@'127.0.0.1';
    CREATE TABLE IF NOT EXISTS flexisip_accounts.accounts (
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      username VARCHAR(255) NOT NULL,
      domain VARCHAR(255) NOT NULL,
      PRIMARY KEY (id),
      UNIQUE KEY account (username, domain)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    CREATE TABLE IF NOT EXISTS flexisip_accounts.passwords (
      account_id BIGINT UNSIGNED NOT NULL,
      password TEXT NOT NULL,
      algorithm VARCHAR(16) NOT NULL,
      PRIMARY KEY (account_id, algorithm),
      CONSTRAINT passwords_account FOREIGN KEY (account_id)
        REFERENCES flexisip_accounts.accounts (id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    FLUSH PRIVILEGES;
    SQL

    domain_hex=$(printf '%s' ${lib.escapeShellArg cfg.domain} | ${pkgs.coreutils}/bin/od -An -v -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n')
    ${pkgs.mariadb}/bin/mariadb --protocol=socket flexisip_accounts <<SQL
    DELETE FROM accounts
      WHERE domain=CONVERT(UNHEX('$domain_hex') USING utf8mb4) COLLATE utf8mb4_unicode_ci;
    SQL
    ${extensionAccountSql}
    ${optionalString cfg.fileTransfer.enable writeFileTransferConfig}
  '';

  writeRoutes = pkgs.writeShellScript "flexisip-write-routes" (
    if isFrontend then
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        cat > ${routesPath} <<'EOF'
        ${routesConf}
        EOF
        # Drop leading indentation from the heredoc.
        ${pkgs.gawk}/bin/awk '{ sub(/^[ \t]+/, ""); if (NF) print }' ${routesPath} > ${routesPath}.tmp
        mv -f ${routesPath}.tmp ${routesPath}
        chown flexisip:flexisip ${routesPath}
        chmod 0640 ${routesPath}
      ''
    else
      ''
        set -euo pipefail
        install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
        : > ${routesPath}
        chown flexisip:flexisip ${routesPath}
      ''
  );

  writeConf = pkgs.writeShellScript "flexisip-write-conf" ''
    set -euo pipefail
    install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
    install -d -o flexisip -g flexisip -m 0750 ${stateDir}/b2b
    ${optionalString cfg.conference.enable ''
      install -d -o flexisip -g flexisip -m 0750 ${conferenceStateDir}
    ''}
    ${optionalString (cfg.messaging.database.enable || cfg.conference.enable) ''
      database_password=$(<${databasePasswordPath})
    ''}
    ${
      if cfg.messaging.database.enable then
        ''
          ${pkgs.gnused}/bin/sed "s/${databasePasswordPlaceholder}/$database_password/g" \
            ${flexisipConfTemplate} > ${confPath}
          chown flexisip:flexisip ${confPath}
          chmod 0640 ${confPath}
        ''
      else
        ''
          install -o flexisip -g flexisip -m 0640 ${flexisipConfTemplate} ${confPath}
        ''
    }
    ${optionalString cfg.conference.enable ''
      ${pkgs.gnused}/bin/sed "s/${databasePasswordPlaceholder}/$database_password/g" \
        ${conferenceConfTemplate} > ${conferenceConfPath}
      chown flexisip:flexisip ${conferenceConfPath}
      chmod 0640 ${conferenceConfPath}
    ''}
  '';

  writeFileTransferConfig = pkgs.writeShellScript "flexisip-write-file-transfer-conf" ''
    set -euo pipefail
    install -d -o flexisip -g flexisip -m 0750 ${runtimeDir}
    database_password=$(<${databasePasswordPath})
    nonce=$(<${databaseStateDir}/file-transfer-nonce)
    ${pkgs.gnused}/bin/sed \
      -e "s/${databasePasswordPlaceholder}/$database_password/g" \
      -e "s/${fileTransferNoncePlaceholder}/$nonce/g" \
      ${fileTransferConfigTemplate} > ${fileTransferConfigPath}
    chown root:flexisip ${fileTransferConfigPath}
    chmod 0640 ${fileTransferConfigPath}
  '';

  preStartAll = pkgs.writeShellScript "flexisip-prestart" ''
    set -euo pipefail
    ${writeAuthDb}
    ${writeProviders}
    ${writeRoutes}
    ${writeConf}
  '';
in
{
  options.smind.services.flexisip = {
    enable = mkEnableOption "Flexisip SIP proxy";

    role = mkOption {
      type = types.enum [
        "frontend"
        "standalone"
      ];
      default = "frontend";
      description = ''
        `frontend` — edge proxy in front of a PBX (Asterisk): TLS termination,
        connection holding, optional push, `reg-on-response` to the backend.
        Asterisk keeps dialplan, trunk, recording, echo, and LAN ATA.

        `standalone` — experimental full PBX replacement (proxy + B2BUA trunk).
        Prefer `frontend` for this household.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.flexisip;
      description = "Flexisip package.";
    };

    domain = mkOption {
      type = types.str;
      example = "pbx.7mind.io";
      description = "SIP domain clients register against.";
    };

    realm = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Digest realm when authentication.enable (defaults to domain).";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = ''
        Local address on which Flexisip binds. With TLS this must be the
        concrete private address behind NAT; the SIP domain remains the
        advertised public address.
      '';
    };

    udpPort = mkOption {
      type = types.port;
      # Default avoids clashing with Asterisk's LAN UDP 5060 in frontend role.
      # Standalone hosts should set this to 5060 explicitly.
      default = 5070;
      description = "UDP SIP listen port for Flexisip.";
    };

    internalUdpPort = mkOption {
      type = types.port;
      default = 5070;
      description = "Localhost-only UDP port (frontend) for hairpinned signalling.";
    };

    extraTransports = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional Flexisip global/transports entries.";
    };

    tls = {
      port = mkOption {
        type = types.port;
        default = 5061;
        description = "Public TLS SIP port.";
      };
      certificateDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "ACME cert directory (fullchain.pem + key.pem).";
      };
    };

    backend = {
      uri = mkOption {
        type = types.str;
        default = "sip:127.0.0.1:5060;transport=udp";
        description = "Asterisk (or other PBX) SIP URI used by frontend Forward routes.";
      };
    };

    authentication = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Flexisip digest authentication (file backend).";
      };
    };

    extensions = mkOption {
      type = types.attrsOf (types.submodule extensionModule);
      default = { };
      description = "Extensions for Flexisip file auth (standalone, or frontend edge auth).";
    };

    mediaRelay = mkOption {
      type = types.bool;
      default = true;
      description = "Enable MediaRelay (useful for internet softphones).";
    };

    preventMediaRelayLoops = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Reject relay destinations that use an address assigned to Flexisip.
        Disable when the downstream media endpoint runs on the same host.
      '';
    };

    forcePublicMediaAddress = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Substitute the public address associated with the advertised SIP
        domain into relayed SDP when Flexisip runs behind NAT.
      '';
    };

    transcoder = mkOption {
      type = types.bool;
      default = false;
      description = "Enable transcoder module. Leave off in frontend (Asterisk transcodes).";
    };

    messaging = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable proper 1:1 SIP MESSAGE handling on the proxy: late fork
          (deliver when the recipient registers) and an optional MariaDB queue.
        '';
      };
      deliveryTimeoutSeconds = mkOption {
        type = types.ints.positive;
        # Default matches upstream (7 days).
        default = 604800;
        description = "How long to retain an undelivered MESSAGE for late fork.";
      };
      acceptTimeoutSeconds = mkOption {
        type = types.ints.positive;
        default = 5;
        description = "How long to wait for a 2xx before accepting for late delivery.";
      };
      database = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Persist undelivered MESSAGE messages through Flexisip's MariaDB
            Soci backend. Disabling this loses queued messages on restart.
          '';
        };
      };
    };

    conference = {
      enable = mkEnableOption "persistent Linphone group chat through Flexisip Conference";
      package = mkOption {
        type = types.package;
        default = pkgs.flexisip-conference;
        description = "Flexisip Conference server package.";
      };
      port = mkOption {
        type = types.port;
        default = 6064;
        description = "Localhost TCP port for the conference server.";
      };
      redisPort = mkOption {
        type = types.port;
        default = 6379;
        description = "Localhost Redis port shared by the proxy and conference server.";
      };
      factoryUser = mkOption {
        type = types.str;
        default = "conference-factory";
        description = "SIP user part advertised as the conference factory.";
      };
      focusUser = mkOption {
        type = types.str;
        default = "conference-focus";
        description = "SIP user part used for generated conference focus URIs.";
      };
      provisioningAccountIndex = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = ''
          Existing Linphone account index to update through a transient
          conference provisioning document. Set this only when the PBX account
          already exists at the selected proxy_N index.
        '';
      };
    };

    presence = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run Flexisip presence server and proxy module::Presence so Linphone
          PUBLISH/SUBSCRIBE presence works. Does not include long-term presence
          (phone-number DB) or resource-list server.
        '';
      };
      port = mkOption {
        type = types.port;
        default = 5065;
        description = "Localhost TCP port for the presence server.";
      };
      publishExpiresSeconds = mkOption {
        type = types.ints.positive;
        default = 600;
        description = "Default Expires for presence PUBLISH.";
      };
    };

    push = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the PushNotification module. This requires a separately
          provisioned APNs/FCM sender; enabling the module alone does not make
          stock Linphone background delivery operational.
        '';
      };
      firebase.serviceAccountFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Optional path to a Firebase service-account JSON (agenix).";
      };
    };

    fileTransfer = {
      enable = mkEnableOption "Linphone-compatible HTTPS photo and file transfer";
      package = mkOption {
        type = types.package;
        default = pkgs.flexisip-http-file-transfer-server;
        description = "Flexisip HTTP file-transfer server package.";
      };
      publicHost = mkOption {
        type = types.str;
        example = "pbx.example.org";
        description = "Public HTTPS hostname configured in Linphone.";
      };
      publicPort = mkOption {
        type = types.port;
        default = 443;
        description = "Public HTTPS port advertised to Linphone.";
      };
      listenPort = mkOption {
        type = types.port;
        default = 8443;
        description = "Internal Apache HTTPS port used by the reverse proxy.";
      };
      maxFileSizeMiB = mkOption {
        type = types.ints.positive;
        default = 32;
        description = "Maximum accepted upload size in MiB.";
      };
      retentionDays = mkOption {
        type = types.ints.positive;
        default = 7;
        description = "Number of days uploaded files remain downloadable.";
      };
    };

    nat.externalMediaAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Public IPv4 for media (standalone B2BUA nat-addresses).";
    };

    # --- standalone-only trunk options (kept for the experimental path) ---
    trunk = {
      enable = mkEnableOption "standalone B2BUA SIP trunk";
      domain = mkOption {
        type = types.str;
        default = "irishvoip.com";
      };
      username = mkOption {
        type = types.str;
        default = "";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
    };

    dialplan = {
      inboundAlias = mkOption {
        type = types.str;
        default = "100";
      };
      ringTimeout = mkOption {
        type = types.ints.positive;
        default = 45;
      };
    };

    b2bua.port = mkOption {
      type = types.port;
      default = 6067;
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open Flexisip TLS (+ optional public UDP) and RTP range.";
    };

    rtpPortRange = {
      from = mkOption {
        type = types.port;
        default = 12000;
      };
      to = mkOption {
        type = types.port;
        default = 12199;
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.rtpPortRange.from < cfg.rtpPortRange.to;
          message = "smind.services.flexisip.rtpPortRange.from must be below .to";
        }
        {
          assertion =
            builtins.bitAnd cfg.rtpPortRange.from 1 == 0 && builtins.bitAnd cfg.rtpPortRange.to 1 == 1;
          message = "smind.services.flexisip.rtpPortRange must start on an even RTP port and end on an odd RTCP port";
        }
        {
          assertion = !cfg.authentication.enable || cfg.extensions != { };
          message = "smind.services.flexisip.authentication.enable requires extensions";
        }
        {
          assertion =
            !(isStandalone && cfg.trunk.enable) || (cfg.trunk.username != "" && cfg.trunk.passwordFile != null);
          message = "standalone trunk requires username and passwordFile";
        }
        {
          assertion = !isFrontend || cfg.backend.uri != "";
          message = "frontend role requires backend.uri (Asterisk SIP URI)";
        }
        {
          assertion = cfg.tls.certificateDir == null || cfg.bindAddress != "0.0.0.0";
          message = "Flexisip TLS behind NAT requires a concrete bindAddress for maddr";
        }
        {
          assertion = !cfg.messaging.database.enable || cfg.messaging.enable;
          message = "messaging.database.enable requires messaging.enable";
        }
        {
          assertion = !cfg.conference.enable || cfg.messaging.enable;
          message = "conference.enable requires messaging.enable";
        }
        {
          assertion =
            !cfg.conference.enable
            || (
              cfg.conference.factoryUser != ""
              && cfg.conference.focusUser != ""
              && cfg.conference.factoryUser != cfg.conference.focusUser
            );
          message = "conference factoryUser and focusUser must be distinct non-empty SIP user parts";
        }
        {
          assertion =
            cfg.conference.provisioningAccountIndex == null
            || (cfg.conference.enable && cfg.fileTransfer.enable);
          message = "conference.provisioningAccountIndex requires conference.enable and fileTransfer.enable";
        }
        {
          assertion =
            !cfg.fileTransfer.enable
            || (
              cfg.tls.certificateDir != null
              && cfg.authentication.enable
              && cfg.extensions != { }
              && builtins.match "[A-Za-z0-9.-]+" cfg.fileTransfer.publicHost != null
            );
          message = "fileTransfer requires TLS, authentication, extensions, and a DNS hostname";
        }
      ];

      users.users.flexisip = {
        isSystemUser = true;
        group = "flexisip";
        home = stateDir;
        createHome = true;
      };
      users.groups.flexisip = { };

      environment.systemPackages = [
        cfg.package
        pkgs.jq
      ];
      environment.etc."flexisip/flexisip.conf.template".source = flexisipConfTemplate;
      environment.etc."flexisip/flexisip-conference.conf.template" = mkIf cfg.conference.enable {
        source = conferenceConfTemplate;
      };

      systemd.services.flexisip-prepare = {
        description = "Prepare Flexisip runtime config and secrets";
        wantedBy = [ "multi-user.target" ];
        before = [
          "flexisip-proxy.service"
          "flexisip-b2bua.service"
          "flexisip-conference.service"
          "flexisip-presence.service"
        ];
        after = [
          "network-online.target"
        ]
        ++ lib.optional databaseEnabled "flexisip-database-prepare.service";
        wants = [ "network-online.target" ];
        requires = lib.optional databaseEnabled "flexisip-database-prepare.service";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = preStartAll;
        };
      };

      systemd.services.flexisip-proxy = {
        description = "Flexisip SIP proxy (${cfg.role})";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "flexisip-prepare.service"
        ]
        ++ lib.optional cfg.conference.enable "redis-flexisip.service"
        ++ lib.optional isFrontend "asterisk.service";
        wants = [ "network-online.target" ];
        requires = [
          "flexisip-prepare.service"
        ]
        ++ lib.optional cfg.conference.enable "redis-flexisip.service";
        serviceConfig = {
          Type = "notify";
          User = "flexisip";
          Group = "flexisip";
          ExecStart = "${cfg.package}/bin/flexisip --server proxy -c ${confPath} --disable-stdout --syslog";
          Restart = "on-failure";
          RestartSec = 2;
          WatchdogSec = 30;
          LimitNOFILE = 524288;
          UMask = "0027";
          StateDirectory = "flexisip";
          LogsDirectory = "flexisip";
          RuntimeDirectory = "flexisip";
          RuntimeDirectoryPreserve = "yes";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            stateDir
            runtimeDir
          ];
          ReadOnlyPaths = lib.optional (cfg.tls.certificateDir != null) cfg.tls.certificateDir;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
        };
      };

      networking.firewall = mkIf cfg.openFirewall {
        # Frontend: only TLS is public. UDP 5070 stays on loopback / LAN as bound.
        allowedTCPPorts = lib.optional (cfg.tls.certificateDir != null) cfg.tls.port;
        allowedUDPPorts = lib.optional (!isFrontend) cfg.udpPort;
        allowedUDPPortRanges = [
          {
            from = cfg.rtpPortRange.from;
            to = cfg.rtpPortRange.to;
          }
        ];
      };
    }

    (mkIf databaseEnabled {
      services.mysql = {
        enable = true;
        package = pkgs.mariadb;
        settings.mysqld.bind-address = "127.0.0.1";
      };

      systemd.services.flexisip-database-prepare = {
        description = "Prepare Flexisip databases";
        wantedBy = [ "multi-user.target" ];
        after = [ "mysql.service" ];
        requires = [ "mysql.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = prepareDatabase;
          UMask = "0027";
        };
      };
    })

    (mkIf cfg.conference.enable {
      services.redis.servers.flexisip = {
        enable = true;
        bind = "127.0.0.1";
        port = cfg.conference.redisPort;
        openFirewall = false;
        appendOnly = true;
      };

      systemd.services.flexisip-conference = {
        description = "Flexisip conference and group-chat server";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "flexisip-prepare.service"
          "flexisip-proxy.service"
          "redis-flexisip.service"
        ];
        wants = [ "network-online.target" ];
        requires = [
          "flexisip-prepare.service"
          "flexisip-proxy.service"
          "redis-flexisip.service"
        ];
        serviceConfig = {
          Type = "notify";
          User = "flexisip";
          Group = "flexisip";
          ExecStart = "${cfg.conference.package}/bin/flexisip-conference -c ${conferenceConfPath} --disable-stdout --syslog";
          Restart = "on-failure";
          RestartForceExitStatus = 5;
          RestartSec = 2;
          WatchdogSec = 30;
          LimitNOFILE = 524288;
          UMask = "0027";
          StateDirectory = "flexisip";
          LogsDirectory = "flexisip";
          RuntimeDirectory = "flexisip";
          RuntimeDirectoryPreserve = "yes";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ReadWritePaths = [
            stateDir
            runtimeDir
          ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
        };
      };
    })

    (mkIf cfg.fileTransfer.enable {
      users.users.wwwrun.extraGroups = [ "flexisip" ];

      systemd.tmpfiles.rules = [
        "d ${fileTransferStateDir} 0750 wwwrun wwwrun -"
      ];

      services.httpd = {
        enable = true;
        enablePHP = true;
        phpPackage = pkgs.php.withExtensions (
          { enabled, all }:
          enabled ++ [ all.mysqli ]
        );
        virtualHosts.${cfg.domain} = {
          listen = [
            {
              ip = cfg.bindAddress;
              port = cfg.fileTransfer.listenPort;
              ssl = true;
            }
          ];
          sslServerCert = "${cfg.tls.certificateDir}/fullchain.pem";
          sslServerKey = "${cfg.tls.certificateDir}/key.pem";
          documentRoot = "${cfg.fileTransfer.package}/share/flexisip-http-file-transfer-server";
          extraConfig = ''
              SSLOptions +StdEnvVars
              SetEnv flexisip_http_file_transfer_config_path ${fileTransferConfigPath}
              SetEnv ap_trust_cgilike_cl 1

              Alias "/linphone-config.xml" "${linphoneProvisioningFile}"
              ${optionalString (cfg.conference.provisioningAccountIndex != null) ''
                Alias "${linphoneConferenceAccountProvisioningPath}" "${linphoneConferenceAccountProvisioningFile}"
              ''}
              Alias "/flexisip-http-file-transfer-server/tmp" "${cfg.fileTransfer.package}/share/flexisip-http-file-transfer-server/download.php"
              Alias "/flexisip-http-file-transfer-server" "${cfg.fileTransfer.package}/share/flexisip-http-file-transfer-server"

              <Directory "${cfg.fileTransfer.package}/share/flexisip-http-file-transfer-server">
                Options FollowSymLinks
                AllowOverride None
                Require all granted
                AcceptPathInfo On
            php_value upload_max_filesize ${toString (cfg.fileTransfer.maxFileSizeMiB + 1)}M
            php_value post_max_size ${toString (cfg.fileTransfer.maxFileSizeMiB + 2)}M
                php_flag log_errors On
                php_value error_log ${fileTransferStateDir}/php-error.log
              </Directory>

              <Location "/linphone-config.xml">
                Require all granted
              </Location>
              ${optionalString (cfg.conference.provisioningAccountIndex != null) ''
                <Location "${linphoneConferenceAccountProvisioningPath}">
                  Require all granted
                </Location>
              ''}
          '';
        };
      };

      systemd.services.httpd = {
        after = [ "flexisip-database-prepare.service" ];
        requires = [ "flexisip-database-prepare.service" ];
        serviceConfig.ReadWritePaths = [ fileTransferStateDir ];
      };

      systemd.services.flexisip-file-transfer-cleanup = {
        description = "Remove expired Linphone file transfers";
        serviceConfig = {
          Type = "oneshot";
          User = "wwwrun";
          Group = "wwwrun";
          ExecStart = pkgs.writeShellScript "flexisip-file-transfer-cleanup" ''
            set -euo pipefail
            ${pkgs.findutils}/bin/find ${fileTransferStateDir} -xdev -mindepth 1 -maxdepth 1 \
              -type f ! -name server.log ! -name php-error.log \
              -mtime +${toString cfg.fileTransfer.retentionDays} -delete
          '';
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [ fileTransferStateDir ];
        };
      };

      systemd.timers.flexisip-file-transfer-cleanup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    })

    (mkIf cfg.presence.enable {
      systemd.services.flexisip-presence = {
        description = "Flexisip presence server";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "flexisip-prepare.service"
          "flexisip-proxy.service"
        ];
        wants = [ "network-online.target" ];
        requires = [ "flexisip-prepare.service" ];
        serviceConfig = {
          Type = "notify";
          User = "flexisip";
          Group = "flexisip";
          ExecStart = "${cfg.package}/bin/flexisip --server presence -c ${confPath} --disable-stdout --syslog";
          Restart = "on-failure";
          RestartSec = 2;
          WatchdogSec = 30;
          LimitNOFILE = 524288;
          UMask = "0027";
          StateDirectory = "flexisip";
          LogsDirectory = "flexisip";
          RuntimeDirectory = "flexisip";
          RuntimeDirectoryPreserve = "yes";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            stateDir
            runtimeDir
          ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
        };
      };
    })

    (mkIf (isStandalone && cfg.trunk.enable) {
      systemd.services.flexisip-b2bua = {
        description = "Flexisip B2BUA (standalone trunk)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "flexisip-prepare.service"
          "flexisip-proxy.service"
        ];
        requires = [ "flexisip-prepare.service" ];
        serviceConfig = {
          Type = "notify";
          User = "flexisip";
          Group = "flexisip";
          ExecStart = "${cfg.package}/bin/flexisip --server b2bua -c ${confPath} --disable-stdout --syslog";
          Restart = "on-failure";
          RestartSec = 2;
          WatchdogSec = 30;
          LimitNOFILE = 524288;
          UMask = "0027";
          StateDirectory = "flexisip";
          LogsDirectory = "flexisip";
          RuntimeDirectory = "flexisip";
          RuntimeDirectoryPreserve = "yes";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            stateDir
            runtimeDir
          ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
          ];
          SystemCallArchitectures = "native";
        };
      };
    })
  ]);
}

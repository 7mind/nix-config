{ pkgs }:

# Behavioral-Active × Effectual × Good Communication; specified runtime-secret contract.
pkgs.testers.runNixOSTest {
  name = "promoted-mosquitto";

  nodes.machine = { config, ... }: {
    imports = [ ../modules/nixos/mosquitto.nix ];
    smind.services.mosquitto.bridge = {
      name = "fixture-upstream";
      address = "127.0.0.1";
      port = 1884;
      username = "fixture-user";
      passwordFile = "/run/fixture-password";
      topics = [ "telemetry/# out 1" "commands/+/set in 1" ];
    };
    services.mosquitto = {
      persistence = false;
      listeners = [ {
        address = "127.0.0.1";
        settings.allow_anonymous = true;
        acl = [ "topic readwrite #" ];
      } ];
    };
    assertions = [ {
      assertion = !config.smind.services.mosquitto.enable
        && (builtins.head config.services.mosquitto.listeners).users == { }
        && config.networking.firewall.allowedTCPPorts == [ ];
      message = "Bridge-only usage must not enable the managed listener or firewall.";
    } ];
  };

  testScript = ''
    import shlex

    start_all()
    machine.wait_for_unit("mosquitto.service")
    machine.succeed("test ! -e /run/mosquitto-bridge/upstream.conf")
    machine.succeed("systemctl show mosquitto-bridge.service -p Before --value | grep -w mosquitto.service")
    machine.succeed("systemctl show mosquitto.service -p Requires --value | grep -w mosquitto-bridge.service")
    password = "fixture-$dollar-'quote-\\backslash"
    machine.succeed("printf '%s\\n' " + shlex.quote(password) + " > /run/fixture-password")
    machine.succeed("systemctl restart mosquitto-bridge.service mosquitto.service")
    machine.wait_for_unit("mosquitto.service")
    generated = machine.succeed("cat /run/mosquitto-bridge/upstream.conf")
    assert "remote_password " + password + "\n" in generated, generated
    for line in ["connection fixture-upstream", "address 127.0.0.1:1884",
                 "remote_username fixture-user", "bridge_protocol_version mqttv311",
                 "cleansession false", "try_private true", "notifications false",
                 "restart_timeout 5 60", "keepalive_interval 30",
                 "max_queued_messages 100000", "topic telemetry/# out 1",
                 "topic commands/+/set in 1"]:
        assert line + "\n" in generated, line
    machine.succeed("test $(stat -c %a:%U:%G /run/mosquitto-bridge) = 750:mosquitto:mosquitto")
    machine.succeed("test $(stat -c %a:%U:%G /run/mosquitto-bridge/upstream.conf) = 640:mosquitto:mosquitto")
    machine.fail("runuser -u nobody -- cat /run/mosquitto-bridge/upstream.conf")
    command = machine.succeed("systemctl show mosquitto.service -p ExecStart --value")
    store_config = command.split(" -c ", 1)[1].split(" ;", 1)[0].strip()
    assert password not in machine.succeed("cat " + shlex.quote(store_config))
    machine.succeed("printf '%s\\n' rotated-fixture > /run/fixture-password")
    machine.succeed("systemctl restart mosquitto-bridge.service mosquitto.service")
    machine.succeed("grep -Fx 'remote_password rotated-fixture' /run/mosquitto-bridge/upstream.conf")
    machine.succeed("printf 'invalid\\npassword' > /run/fixture-password")
    machine.fail("systemctl restart mosquitto-bridge.service")
    machine.succeed("grep -Fx 'remote_password rotated-fixture' /run/mosquitto-bridge/upstream.conf")
    machine.succeed("test $(find /run/mosquitto-bridge -type f | wc -l) = 1")
  '';
}

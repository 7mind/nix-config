{ pkgs }:

let
  lib = pkgs.lib;
  cli = pkgs.writeShellApplication {
    name = "netbird";
    text = ''printf '%s\n' "$NB_INTERFACE_NAME:$NB_WIREGUARD_PORT:$*"'';
  };
  ui = pkgs.runCommand "netbird-ui-fixture" { meta.mainProgram = "netbird-ui"; } ''
    mkdir -p "$out/bin" "$out/share/applications"
    cat > "$out/bin/netbird-ui" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*"
    EOF
    chmod +x "$out/bin/netbird-ui"
    cat > "$out/share/applications/netbird.desktop" <<'EOF'
    [Desktop Entry]
    Type=Application
    Name=NetBird
    Icon=netbird
    Exec=netbird-ui
    EOF
  '';
  evaluate = desktop: extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../modules/nixos/netbird.nix
        ({ lib, ... }: {
          options.smind.isDesktop = lib.mkOption { type = lib.types.bool; };
          config = {
            smind.isDesktop = desktop;
            system.stateVersion = "26.05";
            services.netbird = { package = cli; ui.package = ui; };
          };
        })
        extra
      ];
    }).config;
  headless = evaluate false { };
  desktop = evaluate true { };
  disabledDesktop = evaluate true { smind.net.netbird.enable = false; };
  disabledGraphical = evaluate false { services.xserver.enable = true; };
  enabledHeadless = evaluate false { smind.net.netbird.enable = true; };
  desktopWithoutUI = evaluate true { services.netbird.ui.enable = false; };
  headlessWithUI = evaluate false {
    smind.net.netbird.enable = true;
    services.netbird.ui.enable = true;
  };
  customized = evaluate false {
    smind.net.netbird.enable = true;
    services.netbird.clients.default = { interface = "nb-test"; port = 51842; };
    systemd.network.wait-online.ignoredInterfaces = [ "fixture0" ];
    services.tailscale = { enable = true; useRoutingFeatures = "client"; };
  };
  tailscaleBaseline = evaluate false {
    services.tailscale = { enable = true; useRoutingFeatures = "client"; };
  };
  enabled = [ desktop enabledHeadless desktopWithoutUI headlessWithUI customized ];
  client = config: config.services.netbird.clients.default;
  wrapper = config: (client config).wrapper;
  noEnrollment = config:
    !(client config).login.enable
    && (client config).login.setupKeyFile == null
    && !(config.systemd.services ? netbird-login)
    && !(config.systemd.services.netbird.environment ? NB_SETUP_KEY)
    && !(config.systemd.services.netbird.environment ? NB_MANAGEMENT_URL)
    && !(client config).environment ? NB_MANAGEMENT_URL
    && !(client config).config ? ManagementURL;
in
# BG @specified: public module options plus native NixOS services and wrappers;
# fixture binaries avoid real enrollment, network access, and the UI closure.
assert lib.assertMsg (builtins.all (config:
  !config.smind.net.netbird.enable && !config.services.netbird.enable
  && config.services.netbird.clients == { }
  && !(config.systemd.services ? netbird)
  && !(builtins.elem "wt0" config.systemd.network.wait-online.ignoredInterfaces)
) [ headless disabledDesktop disabledGraphical ]) "Headless defaults and explicit desktop opt-out must not create a NetBird client";
assert lib.assertMsg (disabledGraphical.services.netbird.ui.enable
  && !(builtins.any (package: lib.hasInfix "netbird" package.name) disabledGraphical.environment.systemPackages))
  "Native UI defaults on a disabled graphical host must not install NetBird wrappers";
assert lib.assertMsg (desktop.smind.net.netbird.enable && desktop.services.netbird.enable
  && desktop.services.netbird.ui.enable && (client desktop).ui.enable)
  "Desktop classification must enable the native client and desktop UI by default";
assert lib.assertMsg (enabledHeadless.services.netbird.enable && !enabledHeadless.services.netbird.ui.enable)
  "Explicit headless opt-in must enable the client without UI";
assert lib.assertMsg (!desktopWithoutUI.services.netbird.ui.enable && headlessWithUI.services.netbird.ui.enable)
  "Explicit native UI enable/disable must override classification defaults";
assert lib.assertMsg ((client desktop).interface == "wt0" && (client desktop).port == 51820
  && (client desktop).name == "netbird" && !(client desktop).hardened)
  "Native single-client convenience defaults must remain intact";
assert lib.assertMsg (builtins.all (config:
  config.systemd.services.netbird.serviceConfig.ExecStart == "${lib.getExe (wrapper config)} service run"
  && builtins.elem "multi-user.target" config.systemd.services.netbird.wantedBy
  && builtins.elem (wrapper config) config.environment.systemPackages
  && builtins.elem (client config).interface config.systemd.network.wait-online.ignoredInterfaces
  && noEnrollment config
) enabled) "Enabled clients must expose the native daemon and wrappers, exclude their actual interface from wait-online, and require no automatic login";
assert lib.assertMsg ((client customized).interface == "nb-test" && (client customized).port == 51842
  && builtins.elem 51842 customized.networking.firewall.allowedUDPPorts
  && !(builtins.elem 51820 customized.networking.firewall.allowedUDPPorts)
  && customized.systemd.network.wait-online.ignoredInterfaces == [ "fixture0" "nb-test" ])
  "Native interface/port overrides must propagate while preserving other wait-online exclusions";
assert lib.assertMsg (builtins.all (config:
  config.services.netbird.useRoutingFeatures == "none"
  && config.networking.firewall.checkReversePath == headless.networking.firewall.checkReversePath
) [ desktop enabledHeadless ]) "NetBird must not enable routing features or relax reverse-path filtering";
assert lib.assertMsg (!desktop.services.tailscale.enable
  && customized.services.tailscale.enable
  && customized.services.tailscale.useRoutingFeatures == tailscaleBaseline.services.tailscale.useRoutingFeatures
  && customized.systemd.services.tailscaled.serviceConfig == tailscaleBaseline.systemd.services.tailscaled.serviceConfig)
  "NetBird must leave both disabled and explicitly enabled Tailscale configurations untouched";
pkgs.runCommand "netbird-module" { } ''
  test "$(${wrapper desktop}/bin/netbird status)" = 'wt0:51820:status'
  test "$(${wrapper customized}/bin/netbird status)" = 'nb-test:51842:status'
  for desktopWrapper in ${wrapper desktop} ${wrapper headlessWithUI}; do
    test -x "$desktopWrapper/bin/netbird-ui"
    test "$("$desktopWrapper/bin/netbird-ui" status)" = '--daemon-addr=unix:///var/run/netbird/sock status'
    grep -Fx 'Exec=netbird-ui' "$desktopWrapper/share/applications/netbird.desktop"
    grep -Fx 'Name=NetBird @ netbird' "$desktopWrapper/share/applications/netbird.desktop"
  done
  for headlessWrapper in ${wrapper enabledHeadless} ${wrapper desktopWithoutUI}; do
    test -x "$headlessWrapper/bin/netbird"
    test ! -e "$headlessWrapper/bin/netbird-ui"
    test ! -e "$headlessWrapper/share/applications/netbird.desktop"
  done
  touch "$out"
''

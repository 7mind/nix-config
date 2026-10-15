{ pkgs, home-manager, inputs }:
let
  lib = pkgs.lib;
  extensionPkgs = pkgs.extend (final: _: {
    gnome-shortcut-inhibitor = final.callPackage ../pkg/gnome-shortcut-inhibitor { };
    gnome-shell-extension-classic-app-switcher = final.callPackage ../pkg/classic-app-switcher {
      src = inputs.classic-app-switcher;
    };
    gnome-shell-extension-touchpad-gesture-customization-app-expose =
      inputs.touchpad-gesture-customization-app-expose.packages.${pkgs.stdenv.hostPlatform.system}.default;
  });
  policy = settings: (lib.evalModules {
    modules = [
      (import ../modules/shared/gnome-extensions.nix {
        pkgs = extensionPkgs;
        minimizeModifier = "ctrl-alt";
        defaults = { gsconnect = false; touchpadGestures = false; runOrRaise = true; };
      })
      settings
    ];
  }).config;
  current = policy { classic-app-switcher.enable = true; };
  older = policy { shellVersion = "46"; classic-app-switcher.enable = true; };
  disabledCaffeine = policy { caffeine.enable = false; };
  gestures = policy {
    touchpad-gesture-customization = { enable = true; remap-3-to-4 = true; };
  };
  dock = policy { dash-to-dock.enable = true; };
  unsupported = builtins.tryEval (builtins.toJSON (map (package: package.drvPath)
    (policy { shellVersion = "999"; }).packages));
  uuids = selected: selected.dconfSettings."org/gnome/shell".enabled-extensions;
  find = selected: uuid: lib.findFirst (package: package.extensionUuid == uuid)
    (throw "Missing expected test extension ${uuid}") selected.packages;
  placementUuid = extensionPkgs.gnomeExtensions.native-window-placement.extensionUuid;
  calendarUuid = extensionPkgs.gnomeExtensions.dim-completed-calendar-events.extensionUuid;
  extra = extensionPkgs.gnome46Extensions.${extensionPkgs.gnomeExtensions.hibernate-status-button.extensionUuid};
  home = settings: home-manager.lib.homeManagerConfiguration {
    pkgs = extensionPkgs;
    modules = [
      ../modules/hm/globals.nix
      ../modules/hm/gnome.nix
      ../modules/hm/tailscale.nix
      {
        home = { username = "gnome-test"; homeDirectory = "/build/home"; stateVersion = "26.05"; };
      }
      settings
    ];
  };
  enabledHome = (home {
    smind.hm = {
      desktop.gnome = {
        enable = true;
        extensions = {
          shellVersion = "46";
          classic-app-switcher.enable = true;
          run-or-raise.enable = true;
          extraPackages = [ extra ];
          extraEnabledExtensions = [ "distribution-extension@example.org" ];
        };
      };
      tailscale.systray.enable = true;
    };
  }).config;
  disabledHome = (home { }).config;
  hasUbuntu = builtins.pathExists ../private/modules/hm/ubuntu-gnome.nix;
  ubuntuHome = (home { imports = [ ../private/modules/hm/ubuntu-gnome.nix ]; }).config;
  inheritedHome = (home {
    smind.hm.globals = {
      net.tailscale.enable = true;
      desktop.gnome.extensions.run-or-raise.enable = true;
    };
  }).config;
  selected = enabledHome.smind.hm.desktop.gnome.extensions;
  service = enabledHome.systemd.user.services.tailscale-systray;
  links = enabledHome.xdg.dataFile;
  manifest = pkgs.writeText "gnome-extensions-test.json" (builtins.toJSON (map (package: {
    inherit (package) extensionUuid;
    path = "${package}/share/gnome-shell/extensions/${package.extensionUuid}";
  }) selected.packages));
in
# BG: shared policy and Home Manager; Effectual-Good for built package metadata.
assert lib.assertMsg (uuids current == uuids older) "Shell version selection must preserve extension UUIDs";
assert lib.assertMsg ((find current placementUuid).drvPath == extensionPkgs.gnomeExtensions.native-window-placement.drvPath
  && (find older placementUuid).drvPath == extensionPkgs.gnome46Extensions.${placementUuid}.drvPath)
  "Each Shell version must select its native-window-placement release";
assert lib.assertMsg ((find current calendarUuid).drvPath == extensionPkgs.gnomeExtensions.dim-completed-calendar-events.drvPath
  && (find older calendarUuid).drvPath == extensionPkgs.gnome46Extensions.${calendarUuid}.drvPath)
  "Each Shell version must select its calendar release";
assert lib.assertMsg (!(builtins.elem extensionPkgs.gnomeExtensions.caffeine.extensionUuid (uuids disabledCaffeine)))
  "Disabled extensions must not be enabled";
assert lib.assertMsg (gestures.dconfSettings."org/gnome/shell/extensions/touchpad-gesture-customization".vertical-swipe-3-fingers-gesture == "NONE")
  "Touchpad remapping must preserve the 3-finger drag setting";
assert lib.assertMsg (dock.dconfSettings."org/gnome/shell/extensions/dash-to-dock".click-action == "focus-or-appspread")
  "Dock settings must remain shared";
assert lib.assertMsg (!unsupported.success) "Unsupported GNOME versions must fail, not silently select another version";
assert lib.assertMsg (builtins.elem extra.extensionUuid (uuids selected)
  && builtins.elem "distribution-extension@example.org" (uuids selected))
  "Host-specific and distribution extensions must remain enabled";
assert lib.assertMsg (builtins.all (package:
  links."gnome-shell/extensions/${package.extensionUuid}".source
    == "${package}/share/gnome-shell/extensions/${package.extensionUuid}"
) selected.packages) "Home Manager must install every selected extension in the per-user directory";
assert lib.assertMsg (!(builtins.elem extensionPkgs.gnome-shell enabledHome.home.packages)
  && enabledHome.xdg.desktopEntries."org.gnome.Extensions".exec == "${extensionPkgs.gnome-shell}/bin/gnome-extensions-app"
  && links."applications/org.gnome.Extensions.desktop".source == "${enabledHome.home.path}/share/applications/org.gnome.Extensions.desktop")
  "GNOME provisioning must provide an Extensions launcher independent of the host PATH without shadowing its Shell";
assert lib.assertMsg (!(builtins.elem extensionPkgs.gnome-shell disabledHome.home.packages)
  && !(disabledHome.xdg.desktopEntries ? "org.gnome.Extensions")
  && !(disabledHome.xdg.dataFile ? "applications/org.gnome.Extensions.desktop"))
  "Disabled GNOME provisioning must not install the Extensions app or its launcher";
assert lib.assertMsg (enabledHome.xdg.configFile."run-or-raise/shortcuts.conf".text == ""
  && enabledHome.dconf.settings."org/gnome/shell/extensions/run-or-raise".dbus)
  "run-or-raise must provide its configuration and D-Bus interface";
assert lib.assertMsg (service.Install.WantedBy == [ "graphical-session.target" ]
  && service.Unit.After == [ "graphical-session.target" ]
  && service.Unit.PartOf == [ "graphical-session.target" ]
  && service.Service.Restart == "on-failure"
  && service.Service.ExecStart == [ "${extensionPkgs.tailscale}/bin/tailscale systray" ])
  "Tailscale systray must start with and stop with the graphical session";
assert lib.assertMsg (!(disabledHome.systemd.user.services ? tailscale-systray)
  && !(builtins.any (name: lib.hasPrefix "gnome-shell/extensions/" name) (builtins.attrNames disabledHome.xdg.dataFile)))
  "Disabled provisioning must not install extensions or a systray service";
assert lib.assertMsg (inheritedHome.systemd.user.services ? tailscale-systray
  && inheritedHome.xdg.configFile."run-or-raise/shortcuts.conf".text == "")
  "Existing NixOS host defaults must retain the systray and shortcut file";
assert lib.assertMsg (!hasUbuntu || (let enabled = uuids ubuntuHome.smind.hm.desktop.gnome.extensions; in
  !(builtins.elem extensionPkgs.gnomeExtensions.status-tray.extensionUuid enabled)
  && builtins.elem "ubuntu-appindicators@ubuntu.com" enabled
  && current.status-tray.enable))
  "Ubuntu must use its distribution tray renderer without changing the shared Status Tray default";
assert lib.assertMsg (builtins.all (assertion: assertion.assertion) enabledHome.assertions)
  "Standalone GNOME Home Manager must pass its assertions";
pkgs.runCommand "gnome-extensions" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 - ${manifest} ${links."applications/org.gnome.Extensions.desktop".source} <<'PY'
  import configparser
  import json
  import pathlib
  import sys

  for package in json.loads(pathlib.Path(sys.argv[1]).read_text()):
      metadata = json.loads((pathlib.Path(package["path"]) / "metadata.json").read_text())
      assert metadata["uuid"] == package["extensionUuid"], package
      assert "46" in map(str, metadata["shell-version"]), package
  print("All selected extension packages declare GNOME 46 support")

  desktop = configparser.ConfigParser(interpolation=None)
  desktop.read(sys.argv[2])
  launcher = desktop["Desktop Entry"]
  assert launcher["Exec"] == "${extensionPkgs.gnome-shell}/bin/gnome-extensions-app", launcher["Exec"]
  assert pathlib.Path(launcher["Exec"]).is_file(), launcher["Exec"]
  assert pathlib.Path(launcher["Icon"]).is_file(), launcher["Icon"]
  print("Extensions launcher points to an installed executable and icon")
  PY
  touch "$out"
''

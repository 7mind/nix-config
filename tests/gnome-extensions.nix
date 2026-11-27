{ pkgs, home-manager, inputs }:
let
  lib = pkgs.lib;
  extensionPkgs = ((pkgs.extend (import ../pkg/dim-completed-calendar-events/overlay.nix))
    .extend (import ../pkg/gsconnect/overlay.nix)).extend (final: _: {
    gnome-shortcut-inhibitor = final.callPackage ../pkg/gnome-shortcut-inhibitor { };
    gnome-shell-extension-classic-app-switcher = final.callPackage ../pkg/classic-app-switcher {
      src = inputs.classic-app-switcher;
    };
    gnome-shell-extension-touchpad-gesture-customization-app-expose =
      inputs.touchpad-gesture-customization-app-expose.packages.${pkgs.stdenv.hostPlatform.system}.default;
  });
  policyWithPackages = selectedPkgs: settings: (lib.evalModules {
    modules = [
      (import ../modules/shared/gnome-extensions.nix {
        pkgs = selectedPkgs;
        minimizeModifier = "ctrl-alt";
        defaults = { gsconnect = false; touchpadGestures = false; runOrRaise = true; };
      })
      settings
    ];
  }).config;
  policy = policyWithPackages extensionPkgs;
  shellMajor = lib.versions.major extensionPkgs.gnome-shell.version;
  expectedForShell = shell: package: extensionPkgs."gnome${shell}Extensions".${package.extensionUuid};
  nonNative = policy { shellVersion = "49"; };
  disabledLazy = policyWithPackages (extensionPkgs.extend (_: previous: {
    gnomeExtensions = previous.gnomeExtensions // {
      vicinae = throw "Disabled extension package must not be evaluated";
    };
  })) { vicinae.enable = false; };
  current = policy { classic-app-switcher.enable = true; };
  disabledCaffeine = policy { caffeine.enable = false; };
  gestures = policy {
    touchpad-gesture-customization = { enable = true; remap-3-to-4 = true; };
  };
  dock = policy { dash-to-dock.enable = true; };
  configured = policy {
    gsconnect.enable = true;
    classic-app-switcher.enable = true;
    touchpad-gesture-customization.enable = true;
    dash-to-dock.enable = true;
    no-overview.enable = true;
    extraPackages = [
      inputs.kanata-switcher.packages.${pkgs.stdenv.hostPlatform.system}.gnome-extension
      (extensionPkgs.callPackage ../pkg/hyprwhspr/waveform.nix {
        src = inputs.hyprwhspr;
        shellVersion = shellMajor;
      })
    ];
  };
  roundedCorners = policy { shellVersion = "51"; rounded-window-corners-reborn.enable = true; };
  roundedCornersPackage = extensionPkgs.gnomeExtensions.rounded-window-corners-reborn;
  unavailable = [ "open-bar" "highlight-focus" "tray-icons-reloaded" "dash2dock-lite" ];
  rejectsUnavailable = name: !(builtins.tryEval (builtins.toJSON (map (package: package.drvPath)
    (policy { shellVersion = "51"; ${name}.enable = true; }).packages))).success;
  unsupported = builtins.tryEval (builtins.toJSON (map (package: package.drvPath)
    (policy { shellVersion = "999"; }).packages));
  uuids = selected: selected.dconfSettings."org/gnome/shell".enabled-extensions;
  find = selected: uuid: lib.findFirst (package: package.extensionUuid == uuid)
    (throw "Missing expected test extension ${uuid}") selected.packages;
  placementUuid = extensionPkgs.gnomeExtensions.native-window-placement.extensionUuid;
  calendarUuid = extensionPkgs.gnomeExtensions.dim-completed-calendar-events.extensionUuid;
  calendarSupported = builtins.hasAttr calendarUuid extensionPkgs."gnome${shellMajor}Extensions";
  calendar = extensionPkgs.gnome51Extensions.${calendarUuid};
  calendarPatchedTwice = calendar.overrideAttrs (old: { postPatch = old.postPatch + old.postPatch; });
  quietUuid = extensionPkgs.gnome-shortcut-inhibitor.extensionUuid;
  extra = extensionPkgs.gnomeExtensions.move-clock;
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
          classic-app-switcher.enable = true;
          run-or-raise.enable = true;
          extraPackages = [ extra ];
          extraEnabledExtensions = [ "distribution-extension@example.org" ];
        };
      };
      tailscale.systray.enable = true;
    };
  }).config;
  hibernateCheck = import ./gnome-hibernate.nix { pkgs = extensionPkgs; };
  runtimeCheck = import ./gnome-extension-runtime.nix { inherit pkgs; };
  disabledHome = (home { }).config;
  inheritedHome = (home {
    smind.hm.globals = {
      net.tailscale.enable = true;
      desktop.gnome.extensions.run-or-raise.enable = true;
    };
  }).config;
  selected = enabledHome.smind.hm.desktop.gnome.extensions;
  service = enabledHome.systemd.user.services.tailscale-systray;
  links = enabledHome.xdg.dataFile;
  checkedPolicies = [ selected current gestures dock configured ];
  manifestPackages = lib.unique (lib.concatMap (selected: selected.packages) checkedPolicies ++ [ calendarPatchedTwice ]);
  manifest = pkgs.writeText "gnome-extensions-test.json" (builtins.toJSON (map (package: {
    inherit (package) extensionUuid;
    path = "${package}/share/gnome-shell/extensions/${package.extensionUuid}";
    sourceMetadata = if package.extensionUuid == calendarUuid then "${package.src}/metadata.json" else null;
  }) manifestPackages));
in
# BG: shared policy and Home Manager; Effectual-Good for built package metadata.
assert lib.assertMsg ((find current placementUuid).drvPath == (expectedForShell shellMajor extensionPkgs.gnomeExtensions.native-window-placement).drvPath)
  "Current Shell must select its native-window-placement release";
assert lib.assertMsg (calendarSupported && current.dim-completed-calendar-events.enable
  && (find current calendarUuid).drvPath == (expectedForShell shellMajor extensionPkgs.gnomeExtensions.dim-completed-calendar-events).drvPath)
  "Current Shell must retain the default calendar extension through its bounded compatibility package";
assert lib.assertMsg ((find nonNative placementUuid).drvPath
  == (expectedForShell "49" extensionPkgs.gnomeExtensions.native-window-placement).drvPath)
  "A non-native Shell must select its versioned extension release";
assert lib.assertMsg (builtins.all (shell:
  (find (policy { shellVersion = shell; }) calendarUuid).drvPath
    == pkgs."gnome${shell}Extensions".${calendarUuid}.drvPath
) [ "49" "50" ]) "Calendar compatibility must preserve older Shell catalog selection";
assert lib.assertMsg ((find roundedCorners roundedCornersPackage.extensionUuid).drvPath
  == (expectedForShell "51" roundedCornersPackage).drvPath)
  "Rounded Window Corners Reborn must select its Shell 51 catalog release";
assert lib.assertMsg (builtins.all rejectsUnavailable unavailable)
  "Unavailable optional Shell 51 extensions must still reject explicit enablement";
assert lib.assertMsg (builtins.all (selected:
  lib.sort builtins.lessThan (uuids selected)
    == lib.sort builtins.lessThan (lib.unique ((map (package: package.extensionUuid) selected.packages) ++ selected.extraEnabledExtensions))
) checkedPolicies) "Every selected package must agree with extension activation settings";
assert lib.assertMsg (builtins.deepSeq (map (package: package.drvPath) disabledLazy.packages) true)
  "Disabled extension packages must remain unevaluated";
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
  && enabledHome.xdg.desktopEntries."org.gnome.Extensions".exec == "${extensionPkgs.gnome-extensions-app}/bin/gnome-extensions-app"
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
assert lib.assertMsg current.status-tray.enable "Shared Status Tray must remain enabled by default";
assert lib.assertMsg (builtins.all (assertion: assertion.assertion) enabledHome.assertions)
  "Standalone GNOME Home Manager must pass its assertions";
pkgs.runCommand "gnome-extensions" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  test -s ${hibernateCheck}
  test -e ${runtimeCheck}
  python3 - ${manifest} ${links."applications/org.gnome.Extensions.desktop".source} <<'PY'
  import configparser
  import json
  import pathlib
  import sys

  for package in json.loads(pathlib.Path(sys.argv[1]).read_text()):
      metadata = json.loads((pathlib.Path(package["path"]) / "metadata.json").read_text())
      assert metadata["uuid"] == package["extensionUuid"], package
      versions = list(map(str, metadata["shell-version"]))
      assert "${shellMajor}" in versions, package
      if package["extensionUuid"] == "${quietUuid}":
          assert versions == ["45", "46", "47", "48", "49", "50", "51"], metadata
      if package["sourceMetadata"] is not None:
          source = json.loads(pathlib.Path(package["sourceMetadata"]).read_text())
          expected = dict(source, **{"shell-version": sorted(set(source["shell-version"] + ["51"]))})
          assert metadata == expected, (metadata, expected)
          assert versions.count("51") == 1, metadata
  print("All selected extension packages declare GNOME ${shellMajor} support; UUIDs, previous versions and idempotent calendar metadata preserved")

  desktop = configparser.ConfigParser(interpolation=None)
  desktop.read(sys.argv[2])
  launcher = desktop["Desktop Entry"]
  assert launcher["Exec"] == "${extensionPkgs.gnome-extensions-app}/bin/gnome-extensions-app", launcher["Exec"]
  assert pathlib.Path(launcher["Exec"]).is_file(), launcher["Exec"]
  assert pathlib.Path(launcher["Icon"]).is_file(), launcher["Icon"]
  print("Extensions launcher points to an installed executable and icon")
  PY
  touch "$out"
''

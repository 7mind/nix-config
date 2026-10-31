{ pkgs }:
let
  lib = pkgs.lib;
  extensionPkgs = pkgs.extend (final: _: {
    gnome-shortcut-inhibitor = final.callPackage ../pkg/gnome-shortcut-inhibitor { };
  });
  evaluate = enabled: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    pkgs = extensionPkgs;
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs.cfg-meta = { };
    modules = [
      ../modules/nixos/gnome-extensions.nix
      ({ lib, ... }: {
        options.smind = {
          power-management.hibernate.enable = lib.mkEnableOption "hibernation";
          three-finger-drag.enable = lib.mkEnableOption "three-finger drag";
          keyboard.super-remap = lib.mkOption {
            type = lib.types.attrs;
            default.kanata.keyboards = { };
          };
          kdeconnect.selectedBackend = lib.mkOption {
            type = lib.types.str;
            default = "none";
          };
          desktop.gnome = {
            enable = lib.mkEnableOption "GNOME";
            sticky-keys.enable = lib.mkEnableOption "sticky keys";
            ghostty-toggle.enable = lib.mkEnableOption "Ghostty toggle";
            minimize-modifier = lib.mkOption { type = lib.types.str; default = "ctrl-alt"; };
            dconf.profile = lib.mkOption { type = lib.types.str; default = "user"; };
          };
        };
        config = {
          system.stateVersion = "26.05";
          smind.desktop.gnome.enable = true;
          smind.power-management.hibernate.enable = enabled;
        };
      })
    ];
  }).config;
  enabled = evaluate true;
  disabled = evaluate false;
  uuid = "hibernate-status@dromi";
  hasHibernate = packages: lib.any (package: (package.extensionUuid or "") == uuid) packages;
  extensionPackages = config: config.smind.desktop.gnome.extensions.packages;
  enabledUuids = config: lib.concatMap (database:
    database.settings."org/gnome/shell".enabled-extensions or [ ]
  ) config.programs.dconf.profiles.user.databases;
  hibernate = lib.findFirst (package: (package.extensionUuid or "") == uuid)
    (throw "Missing Hibernate extension") (extensionPackages enabled);
in
# BG: real NixOS selection; built source/schema checks do not execute Shell or power actions.
assert lib.assertMsg (hasHibernate (extensionPackages enabled)
  && hasHibernate enabled.environment.systemPackages
  && builtins.elem uuid (enabledUuids enabled))
  "Enabling hibernation must install and activate the preserved extension";
assert lib.assertMsg (!(hasHibernate (extensionPackages disabled))
  && !(hasHibernate disabled.environment.systemPackages)
  && !(builtins.elem uuid (enabledUuids disabled)))
  "Disabling hibernation must not install or activate its extension";
assert lib.assertMsg (hibernate.version == "42"
  && hibernate.src.outputHash == "03k3fabk72ipa60dssrdbijl2zjg332mci9cagdsy4jdlb41z2gw")
  "The compatibility package must preserve the exact upstream v42 source";
pkgs.runCommand "gnome-hibernate" { nativeBuildInputs = [ pkgs.python3 pkgs.glib ]; } ''
  extension=${hibernate}/share/gnome-shell/extensions/${uuid}
  python3 - "$extension" ${hibernate.src} <<'PY'
  import json
  import pathlib
  import sys
  import xml.etree.ElementTree as ET

  extension, source = map(pathlib.Path, sys.argv[1:])
  metadata = json.loads((extension / "metadata.json").read_text())
  schema_id = "org.gnome.shell.extensions.hibernate-status-button"
  assert metadata["uuid"] == "${uuid}"
  assert metadata["version"] == 42
  assert metadata["settings-schema"] == schema_id
  assert "${lib.versions.major pkgs.gnome-shell.version}" in metadata["shell-version"]
  for name in ["extension.js", "prefs.js", f"schemas/{schema_id}.gschema.xml"]:
      assert (extension / name).read_bytes() == (source / name).read_bytes(), name
  assert (extension / "schemas/gschemas.compiled").is_file()
  schema = ET.parse(extension / f"schemas/{schema_id}.gschema.xml").getroot().find("schema")
  assert schema.attrib == {"id": schema_id, "path": "/org/gnome/shell/extensions/hibernate-status-button/"}
  assert {key.attrib["name"] for key in schema.findall("key")} == {
      "hibernate-works-check", "show-suspend", "show-hibernate", "show-hybrid-sleep",
      "show-suspend-then-hibernate", "show-restart", "show-shutdown", "show-custom-reboot",
      "show-hibernate-dialog", "show-hybrid-sleep-dialog", "show-suspend-then-hibernate-dialog",
  }
  print("Hibernate source/UUID/settings preserved; metadata policy retained, Shell/hardware execution not tested")
  PY
  GSETTINGS_SCHEMA_DIR="$extension/schemas" GSETTINGS_BACKEND=memory \
    gsettings list-recursively org.gnome.shell.extensions.hibernate-status-button > "$out"
  test "$(wc -l < "$out")" -eq 11
''

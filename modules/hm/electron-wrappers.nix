{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hm.electron-wrappers;

  # Wrap an Electron app to run in a resource-limited slice and optionally in a network namespace
  wrapElectronApp = { pkg, name, extraFlags ? [], slice ? "app-heavy.slice", netns ? null }:
    let
      binName = pkg.meta.mainProgram or name;
      flags = lib.concatStringsSep " " extraFlags;
      wrapperScript = if netns != null then ''
#!/usr/bin/env bash
# systemd-run creates scope in slice (resource limits), firejail handles netns
exec systemd-run --user --scope --slice=${slice} \
  /run/wrappers/bin/firejail --noprofile --netns=${netns} -- \
  ${pkg}/bin/${binName} ${flags} "$@"
'' else ''
#!/usr/bin/env bash
exec systemd-run --user --scope --slice=${slice} ${pkg}/bin/${binName} ${flags} "$@"
'';
    in pkgs.runCommand "${name}-wrapped" {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta.mainProgram = binName;
      passAsFile = [ "wrapperScript" ];
      inherit wrapperScript;
    } ''
      mkdir -p $out/bin $out/share

      cp $wrapperScriptPath $out/bin/${binName}
      chmod +x $out/bin/${binName}

      # Copy and patch desktop files
      if [ -d "${pkg}/share/applications" ]; then
        mkdir -p $out/share/applications
        for f in ${pkg}/share/applications/*.desktop; do
          name=$(basename "$f")
          sed "s|Exec=${pkg}/bin/${binName}|Exec=$out/bin/${binName}|g; s|Exec=${binName}|Exec=$out/bin/${binName}|g" "$f" > $out/share/applications/$name
        done
      fi

      # Symlink icons and other share resources
      for dir in ${pkg}/share/*; do
        dirname=$(basename "$dir")
        if [ "$dirname" != "applications" ] && [ ! -e "$out/share/$dirname" ]; then
          ln -s "$dir" "$out/share/$dirname"
        fi
      done
    '';
in
{
  options.smind.hm.electron-wrappers = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable resource-limited Electron app wrappers";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "100%";
      description = "CPU quota for heavy apps slice (100% = 1 core)";
    };

    cpuWeight = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "CPU weight for heavy apps slice (default system weight is 100)";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      description = "Memory limit for heavy apps slice";
    };

    slack.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install wrapped Slack";
    };

    slack.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Slack in (e.g., 'vpn')";
    };

    element.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install wrapped Element";
    };

    element.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Element in (e.g., 'vpn')";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.slices.app-heavy = {
      Unit.Description = "Slice for resource-heavy apps (Slack, Element, etc.)";
      Slice = {
        CPUQuota = cfg.cpuQuota;
        CPUWeight = cfg.cpuWeight;
        MemoryMax = cfg.memoryMax;
      };
      Install.WantedBy = [ "default.target" ];
    };

    home.packages = lib.flatten [
      (lib.optional cfg.slack.enable (wrapElectronApp {
        pkg = pkgs.slack;
        name = "slack";
        extraFlags = [ "-u" ];
        netns = cfg.slack.netns;
      }))
      (lib.optional cfg.element.enable (wrapElectronApp {
        pkg = pkgs.element-desktop;
        name = "element-desktop";
        extraFlags = [ "--hidden" ];
        netns = cfg.element.netns;
      }))
    ];
  };
}

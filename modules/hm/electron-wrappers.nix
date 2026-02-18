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
exec ${pkgs.netns-run}/bin/netns-run -n ${netns} -s ${slice} -- \
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
    enable = lib.mkEnableOption "resource-limited Electron app wrappers";

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

    slack.enable = lib.mkEnableOption "wrapped Slack";

    slack.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Slack in (e.g., 'vpn')";
    };

    slack.autostart = lib.mkOption {
      type = lib.types.bool;
      default = cfg.slack.enable;
      description = "Autostart Slack on login";
    };

    slack.autostartWaitForTray = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wait for StatusNotifierWatcher D-Bus service before starting (ensures tray icon works)";
    };

    slack.autostartTimeout = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Timeout in seconds when waiting for tray service";
    };

    element.enable = lib.mkEnableOption "wrapped Element";

    element.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Element in (e.g., 'vpn')";
    };
  };

  config = lib.mkMerge [
    {
      lib.electron-wrappers.wrapElectronApp = wrapElectronApp;
    }
    (lib.mkIf cfg.enable (
    let
      slackWrapped = wrapElectronApp {
        pkg = pkgs.slack;
        name = "slack";
        extraFlags = [ "-u" ];
        netns = cfg.slack.netns;
      };
      elementWrapped = wrapElectronApp {
        pkg = pkgs.element-desktop;
        name = "element-desktop";
        extraFlags = [ "--hidden" ];
        netns = cfg.element.netns;
      };

      # Wrapper that waits for StatusNotifierWatcher D-Bus service before launching
      waitForTrayWrapper = app: timeout: pkgs.writeShellScript "wait-for-tray-${app.name}" ''
        # Wait for the StatusNotifierWatcher D-Bus service (provided by AppIndicator extension)
        ${pkgs.glib}/bin/gdbus wait --session --timeout=${toString timeout} org.kde.StatusNotifierWatcher || true
        exec ${app}/bin/${app.meta.mainProgram or app.name}
      '';

      slackAutostartExec =
        if cfg.slack.autostartWaitForTray
        then waitForTrayWrapper slackWrapped cfg.slack.autostartTimeout
        else "${slackWrapped}/bin/slack";
    in {
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
        (lib.optional cfg.slack.enable slackWrapped)
        (lib.optional cfg.element.enable elementWrapped)
      ];

      smind.hm.autostart.programs = lib.flatten [
        (lib.optional (cfg.slack.enable && cfg.slack.autostart) {
          name = "Slack";
          exec = toString slackAutostartExec;
        })
      ];
    }
  ))
  ];
}

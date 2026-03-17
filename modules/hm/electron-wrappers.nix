{ config, lib, pkgs, wrapAppWithNetnsSlice, ... }:

let
  cfg = config.smind.hm.electron-wrappers;
in
{
  options.smind.hm.electron-wrappers = {
    enable = lib.mkEnableOption "resource-limited Electron app wrappers";

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "200%";
      description = "CPU quota for heavy apps slice (100% = 1 core)";
    };

    cpuWeight = lib.mkOption {
      type = lib.types.int;
      default = 90;
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

    zoom.enable = lib.mkEnableOption "wrapped Zoom";

    zoom.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Zoom in (e.g., 'vpn')";
    };

    discord.enable = lib.mkEnableOption "wrapped Discord";

    discord.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace to run Discord in (e.g., 'vpn')";
    };
  };

  config = lib.mkMerge [
    {
      lib.electron-wrappers.wrapAppWithNetnsSlice = wrapAppWithNetnsSlice;
    }
    (lib.mkIf cfg.enable (
    let
      slackWrapped = wrapAppWithNetnsSlice {
        pkg = pkgs.slack;
        name = "slack";
        extraFlags = if cfg.slack.autostart then [ "-u" ] else [ ];
        netns = cfg.slack.netns;
      };
      elementWrapped = wrapAppWithNetnsSlice {
        pkg = pkgs.element-desktop;
        name = "element-desktop";
        extraFlags = [ "--hidden" ];
        netns = cfg.element.netns;
      };
      zoomWrapped = wrapAppWithNetnsSlice {
        pkg = pkgs.zoom-us;
        name = "zoom-us";
        extraFlags = [ ];
        netns = cfg.zoom.netns;
      };
      discordWrapped = wrapAppWithNetnsSlice {
        pkg = pkgs.discord;
        name = "discord";
        extraFlags = [ ];
        netns = cfg.discord.netns;
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
        (lib.optional cfg.zoom.enable zoomWrapped)
        (lib.optional cfg.discord.enable discordWrapped)
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

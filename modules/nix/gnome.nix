{ pkgs, lib, ... }: {
  environment.sessionVariables = {
    GTK_THEME = "Adwaita-dark";
    QT_AUTO_SCREEN_SCALE_FACTOR = "1";
    QT_ENABLE_HIGHDPI_SCALING = "1";
    # QT_QPA_PLATFORMTHEME="gnome"; # this breaks Telegram systray icon
    QT_STYLE_OVERRIDE = "adwaita-dark";
  };

  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        lockAll = true; # prevents overriding

        settings = let empty = lib.gvariant.mkEmptyArray lib.gvariant.type.string; in {
          "org/gnome/shell" = {
            disable-user-extensions = false;
            enabled-extensions = [
              pkgs.gnomeExtensions.appindicator.extensionUuid
            ];
          };

          "org/gnome/mutter" = {
            dynamic-workspaces = false;
            edge-tiling = true;
            overlay-key = "";
            #workspaces-only-on-primary = true;
            experimental-features = [
              "scale-monitor-framebuffer"
              "xwayland-native-scaling"
            ];
          };
          "org/gnome/mutter/wayland" = {
            xwayland-allow-grabs = true;
            #xwayland-grab-access-rules=['parsecd']
          };
          "org/gnome/desktop/interface" = {
            #gtk-theme = "Breeze";
            #cursor-theme = "breeze_cursors";
            #icon-theme = "breeze-dark";
            document-font-name = "Noto Sans 11";
            monospace-font-name = "Hack Nerd Font Mono 12";
            cursor-size = lib.gvariant.mkInt32 36;
            font-antialising = "rgba";
            clock-show-weekday = true;
            color-scheme = "prefer-dark";
          };
          "org/gnome/mutter/wayland/keybindings" = {
            restore-shortcuts = lib.gvariant.mkEmptyArray lib.gvariant.type.string;
          };

          "org/gnome/mutter/keybindings" = {
            cancel-input-capture = empty;
            rotate-monitor = empty;
            swithc-monitor = empty;
            toggle-tiled-left = empty;
            toggle-tiled-right = empty;
          };
          "org/gnome/shell/keybindings" = {
            focus-active-notification = empty;
            open-new-window-application-1 = empty;
            open-new-window-application-2 = empty;
            open-new-window-application-3 = empty;
            open-new-window-application-4 = empty;
            open-new-window-application-5 = empty;
            open-new-window-application-6 = empty;
            open-new-window-application-7 = empty;
            open-new-window-application-8 = empty;
            open-new-window-application-9 = empty;

            switch-to-application-1 = empty;
            switch-to-application-2 = empty;
            switch-to-application-3 = empty;
            switch-to-application-4 = empty;
            switch-to-application-5 = empty;
            switch-to-application-6 = empty;
            switch-to-application-7 = empty;
            switch-to-application-8 = empty;
            switch-to-application-9 = empty;

            screenshot = [ "<Shift><Super>3" ];
            screenshot-window = empty; # [ "<Shift><Super><3>space" ]; # doesn't work
            show-screenshot-ui = [ "Print" "<Shift><Super>4" ];
            show-screen-recording-ui = empty;

            shift-overview-up = empty;
            shift-overview-down = empty;

            #open-application-menu = empty;
            toggle-application-view = empty;
            toggle-message-tray = empty;
            toggle-overview = [ "<Super>space" ];
            toggle-quick-settings = empty;
          };
          "org/gnome/settings-daemon/plugins/media-keys" = {
            battery-status = empty;
            battery-status-static = empty;
            calculator = empty;
            calculator-static = empty;
            control-center = empty;
            control-center-static = empty;
            custom-keybindings = empty;
            decrease-text-size = empty;
            eject = empty;
            eject-static = empty;
            email = empty;
            email-static = empty;
            help = empty;
            hibernate = empty;
            hibernate-static = empty;
            home = empty;
            home-static = empty;
            increase-text-size = empty;
            keyboard-brightness-down = empty;
            keyboard-brightness-down-static = empty;
            keyboard-brightness-toggle = empty;
            keyboard-brightness-toggle-static = empty;
            keyboard-brightness-up = empty;
            keyboard-brightness-up-static = empty;
            logout = empty;
            magnifier = empty;
            magnifier-zoom-in = empty;
            magnifier-zoom-out = empty;
            media = empty;
            media-static = empty;
            mic-mute = empty;
            mic-mute-static = empty;
            next = empty;
            next-static = empty;
            on-screen-keyboard = empty;
            pause = empty;
            pause-static = empty;
            play = empty;
            play-static = empty;
            playback-forward = empty;
            playback-forward-static = empty;
            playback-random = empty;
            playback-random-static = empty;
            playback-repeat = empty;
            playback-repeat-static = empty;
            playback-rewind = empty;
            playback-rewind-static = empty;
            power = empty;
            power-static = empty;
            previous = empty;
            previous-static = empty;
            rfkill = empty;
            rfkill-bluetooth = empty;
            rfkill-bluetooth-static = empty;
            rfkill-static = empty;
            rotate-video-lock = empty;
            rotate-video-lock-static = empty;
            screen-brightness-cycle = empty;
            screen-brightness-cycle-static = empty;
            screen-brightness-down = empty;
            screen-brightness-down-static = empty;
            screen-brightness-up = empty;
            screen-brightness-up-static = empty;
            screenreader = empty;
            screensaver-static = empty;
            search = empty;
            search-static = empty;
            stop = empty;
            stop-static = empty;
            suspend = empty;
            suspend-static = empty;
            toggle-contrast = empty;
            touchpad-off = empty;
            touchpad-off-static = empty;
            touchpad-on = empty;
            touchpad-on-static = empty;
            touchpad-toggle = empty;
            touchpad-toggle-static = empty;
            volume-down = empty;
            volume-down-precise = empty;
            volume-down-precise-static = empty;
            volume-down-quiet = empty;
            volume-down-quiet-static = empty;
            volume-down-static = empty;
            volume-mute = empty;
            volume-mute-quiet = empty;
            volume-mute-quiet-static = empty;
            volume-mute-static = empty;
            volume-step = empty;
            volume-up = empty;
            volume-up-precise = empty;
            volume-up-precise-static = empty;
            volume-up-quiet = empty;
            volume-up-quiet-static = empty;
            volume-up-static = empty;
            www = empty;
            www-static = empty;
            screensaver = [ "<Shift><Super>l" ];
          };
          "org/gnome/desktop/wm/keybindings" = {
            activate-window-menu = empty;
            always-on-top = empty;
            begin-move = empty;
            begin-resize = empty;
            cycle-group-backward = empty;
            cycle-panels = empty;
            cycle-panels-backward = empty;
            cycle-windows = empty;
            cycle-windows-backward = empty;
            lower = empty;
            maximize = empty;
            maximize-horizontally = empty;
            maximize-vertically = empty;
            minimize = empty;
            move-to-center = empty;
            move-to-corner-ne = empty;
            move-to-corner-nw = empty;
            move-to-corner-se = empty;
            move-to-corner-sw = empty;
            move-to-monitor-down = empty;
            move-to-monitor-left = empty;
            move-to-monitor-right = empty;
            move-to-monitor-up = empty;
            move-to-side-e = empty;
            move-to-side-n = empty;
            move-to-side-s = empty;
            move-to-side-w = empty;
            move-to-workspace-1 = empty;
            move-to-workspace-10 = empty;
            move-to-workspace-11 = empty;
            move-to-workspace-12 = empty;
            move-to-workspace-2 = empty;
            move-to-workspace-3 = empty;
            move-to-workspace-4 = empty;
            move-to-workspace-5 = empty;
            move-to-workspace-6 = empty;
            move-to-workspace-7 = empty;
            move-to-workspace-8 = empty;
            move-to-workspace-9 = empty;
            move-to-workspace-down = empty;
            move-to-workspace-last = empty;
            move-to-workspace-left = empty;
            move-to-workspace-right = empty;
            move-to-workspace-up = empty;
            panel-main-menu = empty;
            panel-run-dialog = empty;
            raise = empty;
            raise-or-lower = empty;
            set-spew-mark = empty;
            show-desktop = empty;
            switch-applications-backward = empty;
            switch-group = empty;
            switch-group-backward = empty;
            switch-input-source-backward = empty;
            switch-panels = empty;
            switch-panels-backward = empty;
            switch-to-workspace-1 = empty;
            switch-to-workspace-10 = empty;
            switch-to-workspace-11 = empty;
            switch-to-workspace-12 = empty;
            switch-to-workspace-2 = empty;
            switch-to-workspace-3 = empty;
            switch-to-workspace-4 = empty;
            switch-to-workspace-5 = empty;
            switch-to-workspace-6 = empty;
            switch-to-workspace-7 = empty;
            switch-to-workspace-8 = empty;
            switch-to-workspace-9 = empty;
            switch-to-workspace-down = empty;
            switch-to-workspace-last = empty;
            switch-to-workspace-left = empty;
            switch-to-workspace-right = empty;
            switch-to-workspace-up = empty;
            switch-windows-backward = empty;
            toggle-above = empty;
            toggle-fullscreen = empty;
            toggle-on-all-workspaces = empty;
            unmaximize = empty;

            switch-applications = [ "<Super>tab" ]; # system windows with overview
            cycle-group = [ "<Super>grave" ]; # app windows without overview
            switch-windows = empty; # app windows with overview

            close = [ "<Super>q" ];
            switch-input-source = [ "<Primary><Alt><Super>space" ];
            toggle-maximized = [ "<Primary><Alt>f" ];
          };
        };
      }
    ];
  };

  # https://github.com/NixOS/nixpkgs/issues/33277#issuecomment-639281657
  # https://github.com/NixOS/nixpkgs/issues/114514
  services.xserver.desktopManager.gnome = {
    enable = true;
    # extraGSettingsOverridePackages = [ pkgs.mutter ];
    # extraGSettingsOverrides = ''
    #   [org.gnome.mutter]
    #   experimental-features=['scale-monitor-framebuffer', 'xwayland-native-scaling']
    #   [org.gnome.mutter.wayland]
    #   xwayland-allow-grabs=true
    #   xwayland-grab-access-rules=['parsecd']
    # '';
  };

  services.udev.packages = [ pkgs.gnome-settings-daemon ];

  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;

  environment.systemPackages = (with pkgs.gnomeExtensions; [
    appindicator
  ]) ++ (with pkgs; [
    dconf-editor
  ]);

  services.gnome = {
    gnome-settings-daemon.enable = true;
    core-utilities.enable = true;
    core-os-services.enable = true;
    core-shell.enable = true;
    core-developer-tools.enable = true;
    sushi.enable = true;
    gnome-remote-desktop.enable = true;
  };

  programs.gnome-terminal.enable = true;
  programs.gnome-disks.enable = true;
  programs.file-roller.enable = true;
  environment.gnome.excludePackages = with pkgs; [
    orca # text to speech
    epiphany
    gnome-text-editor
    gnome-calculator
    gnome-calendar
    gnome-characters
    gnome-clocks
    gnome-console
    gnome-contacts
    gnome-font-viewer
    gnome-logs
    gnome-maps
    gnome-music
    gnome-weather
    totem
    yelp
    gnome-tour
    gnome-user-docs
    simple-scan
  ];
}

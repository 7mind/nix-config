{ lib, gnome, powerButton }:
lib.mkMerge ([
  {
    "org/gnome/desktop/wm/preferences" = {
      button-layout = gnome.wm.buttonLayout;
    } // lib.optionalAttrs gnome.single-workspace {
      num-workspaces = lib.gvariant.mkInt32 1;
    };
    "org/gnome/desktop/interface" = {
      gtk-theme = "adw-gtk3-dark";
      document-font-name = "Noto Sans 11";
      monospace-font-name = "Hack Nerd Font Mono 12";
      icon-theme = gnome.interface.iconTheme;
      cursor-theme = gnome.interface.cursorTheme;
      cursor-size = lib.gvariant.mkInt32 36;
      font-antialiasing = "rgba";
      clock-show-weekday = true;
      color-scheme = "prefer-dark";
      enable-hot-corners = gnome.hot-corners.enable;
      show-battery-percentage = true;
      # Ghostty 1.3+ respects this; compiled schema default is false
      gtk-enable-primary-paste = true;
    };
    "org/gnome/mutter" = {
      edge-tiling = true;
      overlay-key = "";
      experimental-features =
        lib.optionals gnome.fractional-scaling.enable [
          "scale-monitor-framebuffer"
          "xwayland-native-scaling"
        ]
        ++ lib.optionals gnome.vrr.enable [
          "variable-refresh-rate"
        ];
    } // lib.optionalAttrs gnome.single-workspace {
      dynamic-workspaces = false;
    };
    "org/gnome/shell" = {
      "remember-mount-password" = true;
      "always-show-log-out" = true;
    };
    "org/gnome/desktop/notifications" = {
      show-in-lock-screen = false;
    };
    "org/gnome/desktop/peripherals/mouse" = {
      speed = lib.gvariant.mkDouble gnome.mouse.acceleration;
      accel-profile = gnome.mouse.accelProfile;
      natural-scroll = gnome.mouse.naturalScroll;
    };
    "org/gnome/desktop/peripherals/touchpad" = {
      disable-while-typing = gnome.touchpad.disableWhileTyping;
    };
    "org/gnome/terminal/legacy/keybindings" = {
      copy = "<Super>c";
      paste = "<Super>v";
      new-tab = "<Super>t";
      new-window = "<Super>n";
      close-tab = "<Super>w";
      next-tab = "<Super>bracketright";
      prev-tab = "<Super>bracketleft";
      reset-and-clear = "<Super>k";
      zoom-in = "<Super>plus";
      zoom-out = "<Super>minus";
      zoom-normal = "<Super>0";
    };
    "org/gnome/terminal/legacy" = {
      menu-accelerator-enabled = false;
      new-tab-position = "next";
    };
  }
] ++ lib.optional (gnome.xkb.layouts != [ ]) {
  "org/gnome/desktop/input-sources" =
    let xkb = gnome.xkb;
    in {
      # Layouts already in GNOME's "layout+variant" format
      sources = map (layout: lib.gvariant.mkTuple [ "xkb" layout ]) xkb.layouts;
      per-window = xkb.per-window;
      xkb-options = xkb.options;
    };
} ++ lib.optional gnome.sticky-keys.enable {
  "org/gnome/desktop/a11y/keyboard" = {
    "stickykeys-enable" = true;
    "stickykeys-modifier-beep" = true;
  };
} ++ [{
  "org/gnome/settings-daemon/plugins/power" = {
    idle-brightness = lib.gvariant.mkInt32 100;
    sleep-inactive-ac-type = gnome.auto-suspend.onAC;
    sleep-inactive-battery-type = gnome.auto-suspend.onBattery;
    sleep-inactive-ac-timeout = lib.gvariant.mkInt32 gnome.auto-suspend.timeoutAC;
    sleep-inactive-battery-timeout = lib.gvariant.mkInt32 gnome.auto-suspend.timeoutBattery;
  } // lib.optionalAttrs (powerButton != null) {
    # Let logind handle power button (polkit rule denies gsd-media-keys inhibitor)
    power-button-action = "nothing";
  };
}])

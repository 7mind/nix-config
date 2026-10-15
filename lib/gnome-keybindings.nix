{ lib, gnome, ghosttyCommand, vicinaeCommand }:
let
  xkb = import ./xkb.nix { inherit lib; };
  empty = lib.gvariant.mkEmptyArray lib.gvariant.type.string;
  hotkeyBindings = key: [ (xkb.modifierBinding gnome.hotkey-modifier key) ];
  minimizeBindings = key: [ (xkb.modifierBinding gnome.minimize-modifier key) ];
  toggleOverviewBinding = "<Alt><Super>space";
  vicinaeToggleBindings = hotkeyBindings "space";
  vicinaeTogglePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae-toggle/";
  ghosttyCfg = gnome.ghostty-toggle;
  ghosttyTogglePath = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ghostty-toggle/";
  ghosttyBinding =
    if ghosttyCfg.use-modifier
    then hotkeyBindings ghosttyCfg.key
    else [ ghosttyCfg.key ];
  customKeybindings = gnome.custom-keybindings;
  customKeybindingPaths = map (kb: "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${kb.name}/") customKeybindings;
  customKeybindingSettings = builtins.listToAttrs (map
    (kb: {
      name = "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${kb.name}";
      value = {
        binding = kb.binding;
        command = kb.command;
        name = kb.label;
      };
    })
    customKeybindings);
in
{
  "org/gnome/mutter/wayland/keybindings" = {
    restore-shortcuts = empty;
  };
  "org/gnome/mutter/keybindings" = {
    cancel-input-capture = empty;
    rotate-monitor = empty;
    switch-monitor = empty;
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

    toggle-application-view = empty;
    toggle-message-tray = empty;
    toggle-overview = [ toggleOverviewBinding ];
    toggle-quick-settings = empty;
  };
  "org/gnome/settings-daemon/plugins/media-keys" = {
    battery-status = empty;
    battery-status-static = empty;
    calculator = empty;
    calculator-static = empty;
    control-center = empty;
    control-center-static = empty;
    custom-keybindings = [ vicinaeTogglePath ]
    ++ lib.optional ghosttyCfg.enable ghosttyTogglePath
    ++ customKeybindingPaths;
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
    power = empty;
    power-static = empty;
    previous = empty;
    previous-static = empty;
    rfkill = [ "XF86RFKill" ];
    rfkill-bluetooth = empty;
    rfkill-bluetooth-static = empty;
    rfkill-static = empty;
    rotate-video-lock = empty;
    rotate-video-lock-static = empty;
    screen-brightness-cycle = empty;
    screen-brightness-cycle-static = empty;
    screen-brightness-down = [ "XF86MonBrightnessDown" ];
    screen-brightness-down-static = empty;
    screen-brightness-up = [ "XF86MonBrightnessUp" ];
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
    volume-down = [ "XF86AudioLowerVolume" ];
    volume-down-precise = empty;
    volume-down-precise-static = empty;
    volume-down-quiet = empty;
    volume-down-quiet-static = empty;
    volume-down-static = empty;
    volume-mute = [ "XF86AudioMute" ];
    volume-mute-quiet = empty;
    volume-mute-quiet-static = empty;
    volume-mute-static = empty;
    volume-step = empty;
    volume-up = [ "XF86AudioRaiseVolume" ];
    volume-up-precise = empty;
    volume-up-precise-static = empty;
    volume-up-quiet = empty;
    volume-up-quiet-static = empty;
    volume-up-static = empty;
    www = empty;
    www-static = empty;
    screensaver = [ "<Super><Primary>q" ];
  };
  "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae-toggle" = {
    binding = builtins.head vicinaeToggleBindings;
    command = vicinaeCommand;
    name = "Vicinae Toggle";
  };
} // lib.optionalAttrs ghosttyCfg.enable {
  "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ghostty-toggle" = {
    binding = builtins.head ghosttyBinding;
    command = ghosttyCommand;
    name = "Toggle Ghostty";
  };
} // {
  "org/gnome/desktop/wm/keybindings" = {
    activate-window-menu = empty;
    always-on-top = empty;
    begin-move = empty;
    begin-resize = empty;
    cycle-panels = empty;
    cycle-panels-backward = empty;
    cycle-windows = empty;
    cycle-windows-backward = empty;
    lower = empty;
    maximize = empty;
    maximize-horizontally = empty;
    maximize-vertically = empty;
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
    panel-run-dialog = [ "<Primary><Alt>F2" ];
    raise = empty;
    raise-or-lower = empty;
    set-spew-mark = empty;
    show-desktop = empty;
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
    toggle-above = empty;
    toggle-fullscreen = empty;
    toggle-on-all-workspaces = empty;
    unmaximize = empty;

    switch-windows = if !gnome.switch-applications then hotkeyBindings "tab" else empty; # all windows with overview
    switch-windows-backward = if !gnome.switch-applications then hotkeyBindings "<Shift>tab" else empty;

    switch-applications = if gnome.switch-applications then hotkeyBindings "tab" else empty; # apps with overview
    switch-applications-backward = if gnome.switch-applications then hotkeyBindings "<Shift>tab" else empty;

    switch-group = if gnome.app-window-previews then hotkeyBindings "grave" else empty; # app windows with overview
    switch-group-backward = if gnome.app-window-previews then hotkeyBindings "<Shift>grave" else empty;

    cycle-group = if !gnome.app-window-previews then hotkeyBindings "grave" else empty; # app windows without overview
    cycle-group-backward = if !gnome.app-window-previews then hotkeyBindings "<Shift>grave" else empty;

    close = if gnome.close-window-hotkey then hotkeyBindings "q" else empty;

    switch-input-source =
      if gnome.switch-input-source-keybinding != [ ]
      then gnome.switch-input-source-keybinding
      else empty;
    switch-input-source-backward = empty;

    minimize = minimizeBindings "m";
    toggle-maximized = [ "<Primary><Alt>f" ];
  };
  "org/gnome/desktop/wm/preferences" =
    if gnome.disable-super-drag then {
      mouse-button-modifier = "";
    } else { };
} // customKeybindingSettings

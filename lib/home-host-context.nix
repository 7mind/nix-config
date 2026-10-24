{ lib, config }:

let
  at = path: default:
    let
      step = set: names:
        if names == [ ] then set
        else if set ? ${builtins.head names} then
          step set.${builtins.head names} (builtins.tail names)
        else default;
    in
    step config path;
in
{
  hostname = config.networking.hostName;
  system = config.nixpkgs.hostPlatform.system;
  homeDirectories = lib.mapAttrs (_: user: user.home) config.users.users;
  globals = {
    owner = (at [ "smind" "host" "owner" ] null);
    isDesktop = (at [ "smind" "isDesktop" ] false);
    isLaptop = (at [ "smind" "isLaptop" ] false);
    fonts.terminal = (at [ "smind" "fonts" "terminal" ] "monospace");
    fonts.defaults.sansSerif = (at [ "smind" "fonts" "defaults" "sansSerif" ] [ "sans-serif" ]);
    fonts.defaults.monospace = (at [ "smind" "fonts" "defaults" "monospace" ] [ "monospace" ]);
    desktop.kde.enable = (at [ "smind" "desktop" "kde" "enable" ] false);
    desktop.kde.kde-gtk-config.enable = (at [ "smind" "desktop" "kde" "kde-gtk-config" "enable" ] false);
    desktop.niri.enable = (at [ "smind" "desktop" "niri" "enable" ] false);
    desktop.cosmic.enable = (at [ "smind" "desktop" "cosmic" "enable" ] false);
    desktop.gnome.extensions.run-or-raise.enable = (at [ "smind" "desktop" "gnome" "extensions" "run-or-raise" "enable" ] false);
    desktop.xkb.layouts = (at [ "smind" "desktop" "xkb" "layouts" ] [ "us" ]);
    desktop.xkb.options = (at [ "smind" "desktop" "xkb" "options" ] [ ]);
    desktop.xkb.hotkey-modifier = (at [ "smind" "desktop" "xkb" "hotkey-modifier" ] "super");
    desktop.mouse.acceleration = (at [ "smind" "desktop" "mouse" "acceleration" ] 0.0);
    desktop.mouse.accelProfile = (at [ "smind" "desktop" "mouse" "accelProfile" ] "default");
    desktop.mouse.naturalScroll = (at [ "smind" "desktop" "mouse" "naturalScroll" ] false);
    environment.fileManagers.mc.enable = (at [ "smind" "environment" "fileManagers" "mc" "enable" ] false);
    environment.fileManagers.f4.enable = (at [ "smind" "environment" "fileManagers" "f4" "enable" ] false);
    net.namespaces =
      if at [ "smind" "vpn" "netns" "enable" ] false then
        builtins.attrNames (at [ "smind" "vpn" "netns" "namespaces" ] { })
      else [ ];
    net.tailscale.enable = (at [ "smind" "net" "tailscale" "enable" ] false);
    security.keyring.enable = (at [ "smind" "security" "keyring" "enable" ] false);
    security.keyring.sshAgent = (at [ "smind" "security" "keyring" "sshAgent" ] "standalone");
    three-finger-drag.enable = (at [ "smind" "three-finger-drag" "enable" ] false);
    hw.nvidia.enable = (at [ "smind" "hw" "nvidia" "enable" ] false);
    hw.amd.gpu.enable = (at [ "smind" "hw" "amd" "gpu" "enable" ] false);
    hw.intel.gpu.enable = (at [ "smind" "hw" "intel" "gpu" "enable" ] false);
    nas-autofs.enable = (at [ "smind" "nas-autofs" "enable" ] false);
    llm-worker.sshKeyPath =
      if at [ "smind" "roles" "server" "llm-worker" "enable" ] false then
        at [ "smind" "roles" "server" "llm-worker" "sshKey" "path" ] null
      else null;
    age.enable = (at [ "smind" "age" "enable" ] false);
    age.load-owner-secrets = (at [ "smind" "age" "load-owner-secrets" ] false);
    age.hostPubkey = (at [ "age" "rekey" "hostPubkey" ] null);
    age.masterIdentities = (at [ "age" "rekey" "masterIdentities" ] [ ]);
    age.storageMode = (at [ "age" "rekey" "storageMode" ] null);
    age.localStorageDir = (at [ "age" "rekey" "localStorageDir" ] null);
    age.secrets = (at [ "age" "secrets" ] { });
    llama-swap.enable = (at [ "services" "llama-swap" "enable" ] false);
    llama-swap.port = (at [ "services" "llama-swap" "port" ] null);
    llama-swap.models = (at [ "services" "llama-swap" "settings" "models" ] { });
    ollama.enable = (at [ "services" "ollama" "enable" ] false);
    ollama.modelsDir = (at [ "services" "ollama" "modelsDir" ] null);
  };
}

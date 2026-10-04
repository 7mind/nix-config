# Copy the host projection into smind.hm.fromHost.
# Present only for Home Manager embedded in NixOS or nix-darwin, which passes
# osConfig. Standalone evaluation leaves the option defaults in place.
{ lib, osConfig ? null, ... }:

let
  at = path: default:
    let
      step = set: names:
        if names == [ ] then set
        else if set ? ${builtins.head names} then
          step set.${builtins.head names} (builtins.tail names)
        else default;
    in
    step osConfig path;
in
{
  config = lib.mkIf (osConfig != null) {
    smind.hm.fromHost = {
      owner = lib.mkDefault (at [ "smind" "host" "owner" ] null);
      isDesktop = lib.mkDefault (at [ "smind" "isDesktop" ] false);
      isLaptop = lib.mkDefault (at [ "smind" "isLaptop" ] false);
      fonts.terminal = lib.mkDefault (at [ "smind" "fonts" "terminal" ] "monospace");
      fonts.defaults.sansSerif = lib.mkDefault (at [ "smind" "fonts" "defaults" "sansSerif" ] [ "sans-serif" ]);
      fonts.defaults.monospace = lib.mkDefault (at [ "smind" "fonts" "defaults" "monospace" ] [ "monospace" ]);
      desktop.kde.enable = lib.mkDefault (at [ "smind" "desktop" "kde" "enable" ] false);
      desktop.kde.kde-gtk-config.enable = lib.mkDefault (at [ "smind" "desktop" "kde" "kde-gtk-config" "enable" ] false);
      desktop.niri.enable = lib.mkDefault (at [ "smind" "desktop" "niri" "enable" ] false);
      desktop.cosmic.enable = lib.mkDefault (at [ "smind" "desktop" "cosmic" "enable" ] false);
      desktop.gnome.extensions.run-or-raise.enable = lib.mkDefault (at [ "smind" "desktop" "gnome" "extensions" "run-or-raise" "enable" ] false);
      desktop.xkb.layouts = lib.mkDefault (at [ "smind" "desktop" "xkb" "layouts" ] [ "us" ]);
      desktop.xkb.options = lib.mkDefault (at [ "smind" "desktop" "xkb" "options" ] [ ]);
      desktop.xkb.hotkey-modifier = lib.mkDefault (at [ "smind" "desktop" "xkb" "hotkey-modifier" ] "super");
      desktop.mouse.acceleration = lib.mkDefault (at [ "smind" "desktop" "mouse" "acceleration" ] 0.0);
      desktop.mouse.accelProfile = lib.mkDefault (at [ "smind" "desktop" "mouse" "accelProfile" ] "default");
      desktop.mouse.naturalScroll = lib.mkDefault (at [ "smind" "desktop" "mouse" "naturalScroll" ] false);
      environment.fileManagers.mc.enable = lib.mkDefault (at [ "smind" "environment" "fileManagers" "mc" "enable" ] false);
      environment.fileManagers.f4.enable = lib.mkDefault (at [ "smind" "environment" "fileManagers" "f4" "enable" ] false);
      net.tailscale.enable = lib.mkDefault (at [ "smind" "net" "tailscale" "enable" ] false);
      security.keyring.enable = lib.mkDefault (at [ "smind" "security" "keyring" "enable" ] false);
      security.keyring.sshAgent = lib.mkDefault (at [ "smind" "security" "keyring" "sshAgent" ] "standalone");
      three-finger-drag.enable = lib.mkDefault (at [ "smind" "three-finger-drag" "enable" ] false);
      hw.nvidia.enable = lib.mkDefault (at [ "smind" "hw" "nvidia" "enable" ] false);
      hw.amd.gpu.enable = lib.mkDefault (at [ "smind" "hw" "amd" "gpu" "enable" ] false);
      hw.intel.gpu.enable = lib.mkDefault (at [ "smind" "hw" "intel" "gpu" "enable" ] false);
      nas-autofs.enable = lib.mkDefault (at [ "smind" "nas-autofs" "enable" ] false);
      llm-worker.sshKeyPath = lib.mkDefault (at [ "smind" "roles" "server" "llm-worker" "sshKey" "path" ] null);
      age.enable = lib.mkDefault (at [ "smind" "age" "enable" ] false);
      age.load-owner-secrets = lib.mkDefault (at [ "smind" "age" "load-owner-secrets" ] false);
      age.hostPubkey = lib.mkDefault (at [ "age" "rekey" "hostPubkey" ] null);
      age.masterIdentities = lib.mkDefault (at [ "age" "rekey" "masterIdentities" ] [ ]);
      age.storageMode = lib.mkDefault (at [ "age" "rekey" "storageMode" ] null);
      age.localStorageDir = lib.mkDefault (at [ "age" "rekey" "localStorageDir" ] null);
      age.secrets = lib.mkDefault (at [ "age" "secrets" ] { });
      llama-swap.enable = lib.mkDefault (at [ "services" "llama-swap" "enable" ] false);
      llama-swap.port = lib.mkDefault (at [ "services" "llama-swap" "port" ] null);
      llama-swap.models = lib.mkDefault (at [ "services" "llama-swap" "settings" "models" ] { });
      ollama.enable = lib.mkDefault (at [ "services" "ollama" "enable" ] false);
      ollama.modelsDir = lib.mkDefault (at [ "services" "ollama" "modelsDir" ] null);
    };
  };
}

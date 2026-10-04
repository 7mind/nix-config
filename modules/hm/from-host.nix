# Facts a Home Manager module may read from the surrounding OS.
# Embedded configurations fill these from the host via from-host-bridge.nix.
# Standalone configurations keep the defaults. Modules must not read osConfig,
# nixosConfig, or darwinConfig directly.
{ lib, ... }:

{
  options.smind.hm.fromHost = {
    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is a desktop. Standalone defaults to false.";
    };

    isLaptop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is a laptop.";
    };

    fonts.terminal = lib.mkOption {
      type = lib.types.str;
      default = "monospace";
      description = "Terminal font family projected from the host.";
    };

    fonts.defaults.sansSerif = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "sans-serif" ];
      description = "Sans-serif families projected from the host.";
    };

    fonts.defaults.monospace = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "monospace" ];
      description = "Monospace families projected from the host.";
    };

    desktop.kde.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host KDE session is enabled.";
    };

    desktop.kde.kde-gtk-config.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host allows kde-gtk-config to overwrite GTK settings.";
    };

    desktop.niri.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host Niri session is enabled.";
    };

    desktop.cosmic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host COSMIC session is enabled.";
    };

    desktop.gnome.extensions.run-or-raise.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host enables the GNOME run-or-raise extension.";
    };

    desktop.xkb.layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "us" ];
      description = "Host XKB layouts.";
    };

    desktop.xkb.options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Host XKB options.";
    };

    desktop.xkb.hotkey-modifier = lib.mkOption {
      type = lib.types.str;
      default = "super";
      description = "Host window-switching modifier spec.";
    };

    desktop.mouse.acceleration = lib.mkOption {
      type = lib.types.float;
      default = 0.0;
      description = "Host mouse acceleration.";
    };

    desktop.mouse.accelProfile = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Host mouse acceleration profile.";
    };

    desktop.mouse.naturalScroll = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host natural scrolling.";
    };

    environment.fileManagers.mc.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host installs mc.";
    };

    environment.fileManagers.f4.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host installs f4.";
    };

    net.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host Tailscale service is enabled.";
    };

    security.keyring.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host keyring is enabled.";
    };

    security.keyring.sshAgent = lib.mkOption {
      type = lib.types.str;
      default = "standalone";
      description = "Host SSH agent backend: gcr, standalone, or none.";
    };

    three-finger-drag.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host three-finger-drag is enabled.";
    };

    hw.nvidia.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host NVIDIA GPU support is enabled.";
    };

    hw.amd.gpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host AMD GPU support is enabled.";
    };

    hw.intel.gpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host Intel GPU support is enabled.";
    };

    nas-autofs.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host NAS automounts are enabled.";
    };

    llm-worker.sshKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime path of the llm-worker SSH key, or null.";
    };

    age.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host age integration is enabled.";
    };

    age.load-owner-secrets = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host loads owner age secrets.";
    };

    age.hostPubkey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host age.rekey.hostPubkey.";
    };

    age.masterIdentities = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      description = "Host age.rekey.masterIdentities.";
    };

    age.storageMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host age.rekey.storageMode.";
    };

    age.localStorageDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host age.rekey.localStorageDir.";
    };

    age.secrets = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Host age.secrets. Empty for standalone Home Manager.";
    };

    llama-swap.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host llama-swap service is enabled.";
    };

    llama-swap.port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Host llama-swap port.";
    };

    llama-swap.models = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Host llama-swap model settings, keyed by model id.";
    };

    ollama.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host ollama service is enabled.";
    };

    ollama.modelsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host ollama models directory.";
    };
  };
}

{ config, lib, ... }:

# Audio device quirks - fix misdetected form factors via udev rules
# PipeWire/PulseAudio read ID_SOUND_FORM_FACTOR from udev to classify devices
# Device must be reconnected after rule changes for new properties to apply

{
  options = {
    smind.audio.quirks.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop or false;
      description = "Enable audio device quirks";
    };

    smind.audio.quirks.devices = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable device name (for comments)";
          };
          vendorId = lib.mkOption {
            type = lib.types.str;
            description = "USB vendor ID lowercase (e.g., '0b0e')";
          };
          productId = lib.mkOption {
            type = lib.types.str;
            description = "USB product ID lowercase (e.g., '2e56')";
          };
          formFactor = lib.mkOption {
            type = lib.types.enum [
              "headset"      # Headset with mic
              "headphone"    # Headphones without mic
              "speaker"      # External speakers
              "microphone"   # Standalone mic
              "webcam"       # Webcam with mic
              "handset"      # Phone handset
              "portable"     # Portable speaker
              "car"          # Car audio
              "hifi"         # HiFi equipment
              "internal"     # Internal audio
            ];
            description = "Correct form factor for the device";
          };
        };
      });
      default = [];
      description = "List of audio devices with form factor quirks";
    };
  };

  config = lib.mkIf (config.smind.audio.quirks.enable && config.smind.audio.quirks.devices != []) {
    # Use udev rules to set ID_SOUND_FORM_FACTOR
    # hwdb approach has issues with NixOS build caching
    services.udev.extraRules = lib.concatMapStringsSep "\n" (dev: ''
      # ${dev.name} - set form factor for PipeWire/PulseAudio
      SUBSYSTEM=="sound", ACTION=="add|change", ATTRS{idVendor}=="${dev.vendorId}", ATTRS{idProduct}=="${dev.productId}", ENV{SOUND_FORM_FACTOR}="${dev.formFactor}", ENV{ID_SOUND_FORM_FACTOR}="${dev.formFactor}"
    '') config.smind.audio.quirks.devices;
  };
}

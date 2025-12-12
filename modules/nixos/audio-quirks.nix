{ config, lib, pkgs, ... }:

# Audio device quirks - fix misdetected form factors via udev hwdb
# PipeWire/PulseAudio read ID_SOUND_FORM_FACTOR from udev to classify devices
# hwdb is the proper way to set device properties by USB ID

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
    # Use hwdb to set ID_SOUND_FORM_FACTOR - this is the proper way
    # Format: usb:vXXXXpYYYY* where XXXX=vendor, YYYY=product (uppercase)
    services.udev.extraHwdb = lib.concatMapStringsSep "\n" (dev:
      let
        vid = lib.toUpper dev.vendorId;
        pid = lib.toUpper dev.productId;
      in ''
        # ${dev.name}
        usb:v${vid}p${pid}*
         ID_SOUND_FORM_FACTOR=${dev.formFactor}
      ''
    ) config.smind.audio.quirks.devices;
  };
}

{ config, lib, ... }:

{
  options = {
    smind.audio.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop;
      description = "Enable PipeWire audio with ALSA and PulseAudio compatibility";
    };

    smind.audio.support32Bit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable 32-bit ALSA support (for Steam/Wine/32-bit apps)";
    };
  };

  config = lib.mkIf config.smind.audio.enable {
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = config.smind.audio.support32Bit;
      pulse.enable = true;
    };
  };
}

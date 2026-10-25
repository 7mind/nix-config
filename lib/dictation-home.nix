{ model, device, externalBindings }:
{
  xdg.configFile."hyprwhspr/config.json".text = builtins.toJSON {
    transcription_backend = "qwen3-asr";
    qwen3_asr_model = model;
    qwen3_asr_device = device;
    language = "en";
    external_bindings = externalBindings;
    recording_mode = "toggle";
    mic_osd_enabled = false;
  };
}

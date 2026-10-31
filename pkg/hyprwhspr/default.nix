{
  lib,
  callPackage,
  src,
  runCommand,
  vulkan-tools,
  at-spi2-core,
  libxkbcommon,
}:

let
  runtimes = callPackage ./runtime.nix { };
  runtime = runCommand "hyprwhspr-llama-runtimes" { } ''
    mkdir -p "$out"
    ln -s ${runtimes.cpu} "$out/cpu"
    ln -s ${runtimes.vulkan} "$out/vulkan"
  '';
  upstream = callPackage (src + "/nix/package.nix") { version = "1.50.0"; };
in
upstream.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace lib/src/installation.py \
      --replace-fail "in ('cpu', 'pywhispercpp')" "in ('cpu', 'pywhispercpp', 'qwen3-asr')" \
      --replace-fail 'supports only Whisper.cpp CPU transcription' 'supports Whisper.cpp CPU and Qwen3-ASR transcription'
    substituteInPlace lib/src/qwen3_asr_runtime.py \
      --replace-fail 'return QWEN3_ASR_RUNTIMES_DIR / LLAMA_CPP_RELEASE / device' 'return Path("${runtime}") / device'
    substituteInPlace lib/cli.py \
      --replace-fail 'Nix-managed (beta, Whisper.cpp CPU)' 'Nix-managed (Whisper.cpp CPU and Qwen3-ASR)'
  '';
  buildInputs = old.buildInputs ++ [ at-spi2-core ];
  preFixup = old.preFixup + ''
    wrapProgram "$out/bin/hyprwhspr" \
      --prefix PATH : ${
        lib.makeBinPath [
          vulkan-tools
          libxkbcommon
        ]
      }
  '';
  passthru = old.passthru // {
    inherit runtimes;
  };
  meta = old.meta // {
    description = "Offline desktop dictation with Qwen3-ASR CPU/Vulkan support";
  };
})

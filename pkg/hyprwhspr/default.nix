{
  lib,
  callPackage,
  src,
  runCommand,
  vulkan-tools,
  at-spi2-core,
  libxkbcommon,
  extraBackends ? [ "qwen3-asr" ],
}:

let
  runtimes = callPackage ./runtime.nix { };
  runtime = runCommand "hyprwhspr-llama-runtimes" { } ''
    mkdir -p "$out"
    # Upstream's Nix integration expects bin/ and lib/; the pinned archives are flat.
    for device in cpu vulkan; do
      mkdir -p "$out/$device/bin"
    done
    ln -s ${runtimes.cpu}/llama-server "$out/cpu/bin/llama-server"
    ln -s ${runtimes.cpu} "$out/cpu/lib"
    ln -s ${runtimes.vulkan}/llama-server "$out/vulkan/bin/llama-server"
    ln -s ${runtimes.vulkan} "$out/vulkan/lib"
    echo '${runtimes.cpu.version}' > "$out/version"
  '';
  upstream = callPackage (src + "/nix/package.nix") {
    version = "1.58.0";
    inherit extraBackends;
    backends.qwen3-asr = {
      description = "Qwen3-ASR CPU/Vulkan transcription";
      inherit runtime;
      python = _: [ ];
      wrapperArgs = [
        "--set"
        "HYPRWHSPR_QWEN3_ASR_RUNTIME"
        "${runtime}"
        "--prefix"
        "PATH"
        ":"
        "${lib.getBin vulkan-tools}/bin"
      ];
    };
  };
in
upstream.overrideAttrs (old: {
  postPatch =
    (old.postPatch or "")
    + lib.optionalString (builtins.elem "qwen3-asr" extraBackends) ''
      substituteInPlace lib/cli.py lib/src/cli/status.py \
        --replace-fail 'Nix-managed (beta, Whisper.cpp CPU)' 'Nix-managed (Whisper.cpp CPU and Qwen3-ASR)'
    '';
  buildInputs = old.buildInputs ++ [ at-spi2-core ];
  preFixup = old.preFixup + ''
    wrapProgram "$out/bin/hyprwhspr" \
      --prefix PATH : ${lib.makeBinPath [ libxkbcommon ]}
  '';
  passthru = old.passthru // {
    inherit runtimes;
  };
})

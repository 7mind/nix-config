{
  lib,
  stdenv,
  stdenvNoCC,
  fetchzip,
  makeWrapper,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  bubblewrap,
  procps,
  socat,
}:
let
  version = "2.1.116";

  # Upstream now ships native binaries per platform via @anthropic-ai/claude-code-<platform>.
  # The umbrella @anthropic-ai/claude-code package is just a stub + postinstall that copies
  # the matching native binary into place. We skip the stub and fetch the native pkg directly.
  sources = {
    "x86_64-linux" = {
      pkg = "claude-code-linux-x64";
      hash = "sha256-QEjJ4CRk35TubDNW02Dzcu+EMRLLndJUXJeP3BFT3b8=";
    };
    "aarch64-linux" = {
      pkg = "claude-code-linux-arm64";
      hash = "sha256-/Hqp8GQx8Hub8K4w0Fnx/AksksY61vRC44XxrJVwF5w=";
    };
    "x86_64-darwin" = {
      pkg = "claude-code-darwin-x64";
      hash = "sha256-O3J/ew2fWbUQePs6tHEhK0Q9E3Mx/BDSL7b7NL3FRc8=";
    };
    "aarch64-darwin" = {
      pkg = "claude-code-darwin-arm64";
      hash = "sha256-O41sf7b05SJfXVjszMeTp838mja+PgZ+aEKykLsHeNo=";
    };
  };

  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "claude-code: unsupported system ${stdenvNoCC.hostPlatform.system}");

  isLinux = stdenvNoCC.hostPlatform.isLinux;
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "claude-code";
  inherit version;

  src = fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/${source.pkg}/-/${source.pkg}-${version}.tgz";
    hash = source.hash;
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # The `claude` binary is a Bun single-file executable: bun runtime + appended embedded
  # script payload. patchelf would shift the file size and break Bun's payload-offset
  # detection (it falls back to acting as plain `bun` instead of running the bundled app).
  # So we install the binary verbatim and invoke it via the dynamic loader at runtime.
  installPhase = ''
    runHook preInstall
    install -Dm755 claude $out/libexec/claude-code/claude
    runHook postInstall
  '';

  # `claude` tries to auto-update by default, this disables that functionality.
  # https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview#environment-variables
  postFixup =
    let
      runtimePath = lib.makeBinPath (
        [ procps ] ++ lib.optionals isLinux [ bubblewrap socat ]
      );
    in
    if isLinux then
      ''
        mkdir -p $out/bin
        makeWrapper ${stdenv.cc.bintools.dynamicLinker} $out/bin/claude \
          --add-flags "--library-path ${lib.makeLibraryPath [ stdenv.cc.libc ]} $out/libexec/claude-code/claude" \
          --set DISABLE_AUTOUPDATER 1 \
          --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
          --set DISABLE_INSTALLATION_CHECKS 1 \
          --unset DEV \
          --prefix PATH : ${runtimePath}
      ''
    else
      ''
        mkdir -p $out/bin
        makeWrapper $out/libexec/claude-code/claude $out/bin/claude \
          --set DISABLE_AUTOUPDATER 1 \
          --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
          --set DISABLE_INSTALLATION_CHECKS 1 \
          --unset DEV \
          --prefix PATH : ${runtimePath}
      '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = lib.licenses.unfree;
    mainProgram = "claude";
    platforms = lib.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})

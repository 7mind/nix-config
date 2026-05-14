{
  lib,
  python3,
  fetchFromGitHub,
  stdenvNoCC,
  makeWrapper,
}:
let
  # Upstream has no releases; pin the master commit. README change to
  # `sd-cli` is at this revision, which matches the binary name shipped
  # by nixpkgs `stable-diffusion-cpp*` variants.
  rev = "60697361ffab8d9602d670bde30415496ad2a317";

  pythonEnv = python3.withPackages (ps: [
    ps.gradio
  ]);

  src = fetchFromGitHub {
    owner = "daniandtheweb";
    repo = "sd.cpp-webui";
    inherit rev;
    hash = "sha256-F4X+3Zka7vYqXGI2O+qfzlgW3b6pUM5ZWYhxvE8PR98=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "sdcpp-webui";
  version = "0-unstable-2026-05-10";

  inherit src;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # Upstream is run as `python3 sdcpp_webui.py` from its own directory.
  # The script looks for sibling `modules/<type>/`, `outputs/<type>/`,
  # and `user_data/config.json` relative to CWD. We install the tree
  # under libexec and emit a wrapper that does NOT chdir — the systemd
  # unit sets WorkingDirectory to a writable StateDirectory so the
  # `models/` and `outputs/` trees live on disk, not in /nix/store.
  #
  # The `sd-cli` / `sd-server` binary is NOT bundled here. The module
  # appends the chosen stable-diffusion-cpp variant (cuda/rocm/vulkan)
  # to the unit's PATH so a single webui package serves all backends.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/sdcpp-webui
    cp -r . $out/libexec/sdcpp-webui/
    makeWrapper ${pythonEnv}/bin/python $out/bin/sdcpp-webui \
      --add-flags "$out/libexec/sdcpp-webui/sdcpp_webui.py"
    runHook postInstall
  '';

  passthru = {
    inherit pythonEnv;
  };

  meta = {
    description = "Gradio webui for stable-diffusion.cpp";
    homepage = "https://github.com/daniandtheweb/sd.cpp-webui";
    license = lib.licenses.agpl3Only;
    mainProgram = "sdcpp-webui";
    platforms = lib.platforms.linux;
  };
}

{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  vulkan-loader,
  curl,
  openssl,
}:

let
  release = "b10516";
  runtime =
    device: filename: hash:
    stdenvNoCC.mkDerivation {
      pname = "hyprwhspr-llama-${device}";
      version = release;
      src = fetchurl {
        url = "https://github.com/ggml-org/llama.cpp/releases/download/${release}/${filename}";
        sha256 = hash;
      };
      nativeBuildInputs = [ autoPatchelfHook ];
      buildInputs = [
        stdenv.cc.cc.lib
        curl
        openssl
      ]
      ++ lib.optional (device == "vulkan") vulkan-loader;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp -a llama-server *.so* LICENSE "$out/"
        runHook postInstall
      '';
      meta = {
        license = lib.licenses.mit;
        platforms = [ "x86_64-linux" ];
      };
    };
in
{
  cpu =
    runtime "cpu" "llama-b10516-bin-ubuntu-x64.tar.gz"
      "f263a91280471b4c33c4999d7c76259c0f3a0a53a0b3e692b2c0b84380137a35";
  vulkan =
    runtime "vulkan" "llama-b10516-bin-ubuntu-vulkan-x64.tar.gz"
      "5ce186720f43c415465869b0cd93973b828b219cbf6fbcc22aa899531973c505";
}

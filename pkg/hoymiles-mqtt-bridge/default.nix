{
  lib,
  python3,
  fetchFromGitHub,
  stdenvNoCC,
  makeWrapper,
}:
let
  hoymilesWifiVersion = "0.6.0";

  # Upstream library: not in nixpkgs, packaged inline. Pure-Python protobuf
  # client for the local Hoymiles DTU/HMS-W protocol.
  hoymiles-wifi = python3.pkgs.buildPythonPackage rec {
    pname = "hoymiles-wifi";
    version = hoymilesWifiVersion;
    pyproject = true;

    src = fetchFromGitHub {
      owner = "suaveolent";
      repo = "hoymiles-wifi";
      rev = "v${version}";
      hash = "sha256-+24A3vBU3uMsT66IhMOb/zU5OE2Boss5jl2qvmkXTxE=";
    };

    build-system = [ python3.pkgs.setuptools ];

    dependencies = with python3.pkgs; [
      protobuf
      crcmod
      cryptography
    ];

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      python -m unittest discover -s tests -v
      runHook postCheck
    '';
    pythonImportsCheck = [ "hoymiles_wifi" "hoymiles_wifi.dtu" ];

    meta = {
      description = "Local protobuf client for Hoymiles DTUs and HMS-W inverters";
      homepage = "https://github.com/suaveolent/hoymiles-wifi";
      license = lib.licenses.mit;
    };
  };

  pythonEnv = python3.withPackages (ps: [
    hoymiles-wifi
    ps.aiomqtt
  ]);

  typecheckEnv = python3.withPackages (ps: [
    hoymiles-wifi
    ps.aiomqtt
    ps.mypy
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "hoymiles-mqtt-bridge";
  version = "0.1.0";

  src = ./hoymiles_mqtt_bridge.py;

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${typecheckEnv}/bin/python -m py_compile $src
    ${pythonEnv}/bin/python $src --help > /dev/null
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/libexec/hoymiles-mqtt-bridge/hoymiles_mqtt_bridge.py
    makeWrapper ${pythonEnv}/bin/python $out/bin/hoymiles-mqtt-bridge \
      --add-flags "$out/libexec/hoymiles-mqtt-bridge/hoymiles_mqtt_bridge.py"
    runHook postInstall
  '';

  passthru = {
    inherit hoymiles-wifi pythonEnv;
  };

  meta = {
    description = "Hoymiles → MQTT bridge with Home Assistant discovery";
    license = lib.licenses.mit;
    mainProgram = "hoymiles-mqtt-bridge";
    platforms = lib.platforms.linux;
  };
}

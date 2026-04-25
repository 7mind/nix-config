{
  lib,
  python3,
  stdenvNoCC,
  makeWrapper,
}:
let
  pythonEnv = python3.withPackages (ps: [
    ps.python-matter-server
    ps.aiomqtt
    ps.aiohttp
  ]);

  typecheckEnv = python3.withPackages (ps: [
    ps.python-matter-server
    ps.aiomqtt
    ps.aiohttp
    ps.mypy
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "matter-mqtt-bridge";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    PYTHONPYCACHEPREFIX="$TMPDIR/pycache" \
      ${typecheckEnv}/bin/python -m py_compile $src/matter_mqtt_bridge.py
    ${python3}/bin/python -m unittest discover -s $src/tests -p 'test_*.py'
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 $src/matter_mqtt_bridge.py $out/libexec/matter-mqtt-bridge/matter_mqtt_bridge.py
    makeWrapper ${pythonEnv}/bin/python $out/bin/matter-mqtt-bridge \
      --add-flags "$out/libexec/matter-mqtt-bridge/matter_mqtt_bridge.py"
    runHook postInstall
  '';

  passthru = {
    inherit pythonEnv;
  };

  meta = {
    description = "Matter → MQTT bridge for python-matter-server";
    license = lib.licenses.mit;
    mainProgram = "matter-mqtt-bridge";
    platforms = lib.platforms.linux;
  };
}

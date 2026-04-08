{ lib, pkgs, stdenvNoCC, makeWrapper }:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    paho-mqtt
  ]);

  # Type-checking python: runtime env plus mypy. Built separately so mypy
  # doesn't end up on the runtime PYTHONPATH.
  typecheckEnv = pkgs.python3.withPackages (ps: with ps; [
    paho-mqtt
    mypy
  ]);
in
stdenvNoCC.mkDerivation {
  name = "zigbee-mqtt-import";
  src = ./zigbee_mqtt_import.py;

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${typecheckEnv}/bin/mypy --strict --no-color-output $src
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/zigbee-mqtt-import
    chmod +x $out/bin/zigbee-mqtt-import
    wrapProgram $out/bin/zigbee-mqtt-import \
      --set PYTHONPATH "${pythonEnv}/${pythonEnv.sitePackages}" \
      --prefix PATH : ${lib.makeBinPath [ pythonEnv ]}
    runHook postInstall
  '';

  meta = with lib; {
    description = "Dump zigbee2mqtt friendly_name → ieee_address mapping as JSON";
    license = licenses.mit;
    maintainers = with maintainers; [ pshirshov ];
    mainProgram = "zigbee-mqtt-import";
    platforms = platforms.all;
  };
}

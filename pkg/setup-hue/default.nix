{ lib, pkgs, stdenvNoCC, makeWrapper }:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    paho-mqtt
    pydantic
  ]);

  # Type-checking python: runtime env plus mypy. Built separately so mypy
  # doesn't end up on the runtime PYTHONPATH.
  typecheckEnv = pkgs.python3.withPackages (ps: with ps; [
    paho-mqtt
    pydantic
    mypy
  ]);
in
stdenvNoCC.mkDerivation {
  name = "setup-hue";
  src = ./setup_hue.py;

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
    cp $src $out/bin/setup-hue
    chmod +x $out/bin/setup-hue
    wrapProgram $out/bin/setup-hue \
      --set PYTHONPATH "${pythonEnv}/${pythonEnv.sitePackages}" \
      --prefix PATH : ${lib.makeBinPath [ pythonEnv ]}
    runHook postInstall
  '';

  meta = with lib; {
    description = "Declarative zigbee2mqtt group and scene setup over MQTT";
    license = licenses.mit;
    maintainers = with maintainers; [ pshirshov ];
    mainProgram = "setup-hue";
    platforms = platforms.all;
  };
}

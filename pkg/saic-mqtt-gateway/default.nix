{
  lib,
  python3,
  fetchPypi,
  fetchFromGitHub,
  stdenvNoCC,
  makeWrapper,
}:
let
  gatewayVersion = "0.10.0";

  # Upstream library package. Not yet in nixpkgs, so we build it here.
  saic-ismart-client-ng = python3.pkgs.buildPythonPackage rec {
    pname = "saic-ismart-client-ng";
    version = "0.9.3";
    pyproject = true;

    src = fetchPypi {
      pname = "saic_ismart_client_ng";
      inherit version;
      hash = "sha256-XQ968t9ydbM/iZXB1ekOClLpmWH5hgRQuum7+scwGa0=";
    };

    build-system = [ python3.pkgs.poetry-core ];

    dependencies = with python3.pkgs; [
      pycryptodome
      httpx
      tenacity
      dacite
    ];

    # Upstream ships tests but not inside the sdist; nothing to run here.
    doCheck = false;

    pythonImportsCheck = [ "saic_ismart_client_ng" ];

    meta = {
      description = "SAIC next-gen client library (MG iSMART)";
      homepage = "https://github.com/SAIC-iSmart-API/saic-python-client-ng";
      license = lib.licenses.mit;
    };
  };

  pythonEnv = python3.withPackages (ps: [
    saic-ismart-client-ng
    ps.httpx
    ps.gmqtt
    ps.inflection
    ps.apscheduler
    ps.python-dotenv
  ]);

  src = fetchFromGitHub {
    owner = "SAIC-iSmart-API";
    repo = "saic-python-mqtt-gateway";
    rev = gatewayVersion;
    hash = "sha256-+riwp740dCWBOMDDIeTlvB8466DiBbHXoY2zaR5PtLE=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "saic-mqtt-gateway";
  version = gatewayVersion;

  inherit src;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # Upstream uses poetry with package-mode = false: the gateway is not built as
  # an installable package, it's run as `python src/main.py`. We copy src/ into
  # libexec and provide a wrapped entry point that invokes the module.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/saic-mqtt-gateway
    cp -r src/. $out/libexec/saic-mqtt-gateway/
    cp -r examples $out/libexec/saic-mqtt-gateway/examples
    makeWrapper ${pythonEnv}/bin/python $out/bin/saic-mqtt-gateway \
      --add-flags "$out/libexec/saic-mqtt-gateway/main.py" \
      --chdir "$out/libexec/saic-mqtt-gateway"
    runHook postInstall
  '';

  passthru = {
    inherit saic-ismart-client-ng pythonEnv;
  };

  meta = {
    description = "MQTT gateway for MG iSMART (SAIC) cars";
    homepage = "https://github.com/SAIC-iSmart-API/saic-python-mqtt-gateway";
    license = lib.licenses.mit;
    mainProgram = "saic-mqtt-gateway";
    platforms = lib.platforms.linux;
  };
}

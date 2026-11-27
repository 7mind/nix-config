{
  lib,
  python3,
  fetchPypi,
}:
let
  # ChristopheHD/enocean: ESP3 protocol library + EEP decoders.
  # Not in nixpkgs.
  enocean = python3.pkgs.buildPythonPackage rec {
    pname = "enocean";
    version = "1.0.0";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-/qMZTUMN1VnmfTQoLTanNnsH26kUw4H5Y9NQwgHYQb8=";
    };

    dependencies = with python3.pkgs; [
      pyserial
      cryptography
    ];

    doCheck = false;
    pythonImportsCheck = [
      "enocean"
      "enocean.protocol"
      "enocean.communicators"
    ];

    meta = {
      description = "EnOcean serial protocol implementation (ESP3 + EEP)";
      homepage = "https://github.com/ChristopheHD/enocean";
      license = lib.licenses.mit;
    };
  };

  enocean-mqtt-pylib = python3.pkgs.buildPythonPackage rec {
    pname = "enocean-mqtt";
    version = "0.1.4";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-RTbMEuP8wrji6BhwU8v5+QkQNXa1TpFP5ghCy2TIMy8=";
    };

    dependencies = with python3.pkgs; [
      enocean
      paho-mqtt
    ];

    doCheck = false;
    pythonImportsCheck = [ "enoceanmqtt" ];

    meta = {
      description = "Bridge from EnOcean serial interface to MQTT";
      homepage = "https://github.com/embyt/enocean-mqtt";
      license = lib.licenses.gpl3Only;
      mainProgram = "enoceanmqtt";
    };
  };
in
enocean-mqtt-pylib.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit enocean;
  };
})

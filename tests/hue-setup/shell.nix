let
  pkgs = import <nixpkgs> { };
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    pytest
    pytest-xdist
    paho-mqtt
    pydantic
  ]);
in
pkgs.mkShellNoCC {
  name = "hue-setup-tests";
  packages = [
    pkgs.mosquitto
    pythonEnv
  ];
  shellHook = ''
    echo "hue-setup test shell ready"
    echo "  mosquitto: $(mosquitto -h 2>&1 | head -1)"
    echo "  python:    $(python3 --version)"
    echo "  pytest:    $(pytest --version 2>&1 | head -1)"
    echo
    echo "run: pytest -v"
  '';
}

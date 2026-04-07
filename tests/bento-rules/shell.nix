let
  pkgs = import <nixpkgs> { };
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    pytest
    paho-mqtt
  ]);
in
pkgs.mkShellNoCC {
  name = "bento-rules-tests";
  packages = [
    pkgs.bento
    pkgs.mosquitto
    pythonEnv
  ];
  shellHook = ''
    echo "bento-rules test shell ready"
    echo "  bento:     $(bento --version 2>/dev/null | head -1)"
    echo "  mosquitto: $(mosquitto -h 2>&1 | head -1)"
    echo "  python:    $(python3 --version)"
    echo "  pytest:    $(pytest --version 2>&1 | head -1)"
    echo
    echo "run: pytest -v"
  '';
}

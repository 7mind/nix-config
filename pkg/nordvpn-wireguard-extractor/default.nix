{ pkgs, lib, python3 }:

let
  pname = "nordvpn-wireguard-extractor";
  version = "0.1.0";
in
python3.pkgs.buildPythonApplication {
  inherit pname version;

  src = ./.;

  pyproject = true;

    nativeBuildInputs = [
    python3.pkgs.setuptools
    python3.pkgs.wheel
  ];

  makeWrapperArgs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    "--prefix" "PATH" ":" (lib.makeBinPath [ pkgs.iproute2 pkgs.wireguard-tools pkgs.curl ])
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = with lib; {
    description = "A script to extract NordVPN WireGuard configurations.";
    homepage = "https://gist.github.com/pshirshov/80acc5f94d259b9c3a05680ba606bae8";
    license = licenses.mit; # Assuming MIT, as it's a gist
    maintainers = with maintainers; [ ];
  };
}

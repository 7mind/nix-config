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

  # This package has no external dependencies, so we don't need to specify them.

  meta = with lib; {
    description = "A script to extract NordVPN WireGuard configurations.";
    homepage = "https://gist.github.com/pshirshov/80acc5f94d259b9c3a05680ba606bae8";
    license = licenses.mit; # Assuming MIT, as it's a gist
    maintainers = with maintainers; [ ];
  };
}

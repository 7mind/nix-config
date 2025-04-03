{ lib, stdenvNoCC, cfg-meta, ... }:

stdenvNoCC.mkDerivation rec {
  pname = "nix-quick-install";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [
  ];

  installPhase = ''
    mkdir -p $out/bin
    cp ${src}/qinstall.sh $out/bin/nix-quick-install

    cp ${src}/seed.nix $out/seed.nix
    cp ${src}/seed-flake.nix $out/seed-flake.nix

    #cp "${cfg-meta.paths.modules}/nix/auto/any.nix" $out/any.nix
    #cp "${cfg-meta.paths.modules}/nix/auto/any-nixos-generic.nix" $out/any-nixos-generic.nix

    chmod a+x $out/bin/nix-quick-install
  '';

  meta = with lib; {
    description = "nix-quick-install";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.linux;
  };
}

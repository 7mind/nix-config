{ lib, pkgs, stdenvNoCC, makeWrapper }:

stdenvNoCC.mkDerivation {
  name = "extract-initrd";
  src = ./extract-initrd.py;

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [
    pkgs.python3
    pkgs.coreutils
    pkgs.zstd
    pkgs.cpio
  ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/extract-initrd
    chmod +x $out/bin/extract-initrd
    wrapProgram $out/bin/extract-initrd \
      --prefix PATH : ${lib.makeBinPath [ pkgs.python3 pkgs.coreutils pkgs.zstd pkgs.cpio ]}
    runHook postInstall
  '';

  meta = with lib; {
    description = "Extract NixOS initrd to a directory";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

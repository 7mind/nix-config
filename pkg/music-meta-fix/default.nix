{ lib, pkgs, stdenvNoCC, makeWrapper }:

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.mutagen ]);
in
stdenvNoCC.mkDerivation {
  name = "music-meta-fix";
  src = ./music-meta-fix.py;

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp $src $out/bin/music-meta-fix
    chmod +x $out/bin/music-meta-fix
    wrapProgram $out/bin/music-meta-fix \
      --set PYTHONPATH "${pythonEnv}/${pythonEnv.sitePackages}" \
      --prefix PATH : ${lib.makeBinPath [ pythonEnv ]}
    runHook postInstall
  '';

  meta = with lib; {
    description = "Find and fix music files with missing title/album metadata";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.all;
  };
}

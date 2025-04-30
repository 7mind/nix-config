{ lib, pkgs, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "stalix-cache";

  src = ./stalix-cache.sh;

  builder = pkgs.writeText "builder.sh" ''
    mkdir -p $out/bin
    cp $src $out/bin/$name
    chmod +x $out/bin/$name
  '';

  meta = with lib; {
    description = "stalix cache";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

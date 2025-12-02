{ lib, pkgs, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "firejail-wrap";
  src = ./firejail-wrap.sh;

  builder = pkgs.writeText "builder.sh" ''
    mkdir -p $out/bin
    cp $src $out/bin/$name
    chmod +x $out/bin/$name
  '';

  meta = with lib; {
    description = "Universal firejail wrapper with path whitelisting";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

{ lib, pkgs, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "qendercore-pull";

  src = ./qendercore-pull.py;

  builder = pkgs.writeText "builder.sh" ''
    mkdir -p $out/bin
    cp $src $out/bin/$name
    chmod +x $out/bin/$name
  '';

  meta = with lib; {
    description = "qendercore poller";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.unix;
  };
}

{ lib, pkgs, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "firejail-wrap";
  src = pkgs.replaceVars ./firejail-wrap.sh { firejail = pkgs.firejail; };

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

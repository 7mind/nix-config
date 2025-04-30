{ lib, pkgs, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "ip-update";
  src = pkgs.replaceVars ./ip-update.sh { aws = pkgs.awscli2; };

  builder = pkgs.writeText "builder.sh" ''
    mkdir -p $out/bin
    cp $src $out/bin/$name
    chmod +x $out/bin/$name
  '';

  meta = with lib; {
    description = "route 53 ip update";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

{ substituteAll, lib, pkgs }:

substituteAll {
  name = "ip-update";
  src = ./ip-update.sh;
  aws = pkgs.awscli2;

  dir = "bin";
  isExecutable = true;

  meta = with lib; {
    description = "route 53 ip update";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

{ substituteAll, lib }:

substituteAll {
  name = "stalix-cache";
  src = ./stalix-cache.sh;

  dir = "bin";
  isExecutable = true;

  meta = with lib; {
    description = "stalix cache";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
  };
}

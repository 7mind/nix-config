{ substituteAll, lib }:

substituteAll {
  name = "qendercore-pull";
  src = ./qendercore-pull.py;

  dir = "bin";
  isExecutable = true;

  meta = with lib; {
    description = "qendercore poller";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.unix;
  };
}

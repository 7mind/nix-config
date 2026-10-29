{
  source = "pavel-testbench";
  username = "pavel";
  host = {
    hostname = "ubuntu";
    system = "x86_64-linux";
    homeDirectories.pavel = "/home/pavel";
    globals.isDesktop = true;
  };
}

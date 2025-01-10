{ ... }: {
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
    };
    openFirewall = true;
  };

}

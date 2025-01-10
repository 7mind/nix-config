{ ... }: {
  programs.ssh = {
    enable = true;
    addKeysToAgent = "yes";
    extraConfig = ''
      IgnoreUnknown UseKeychain
      UseKeychain yes
    '';
  };
}

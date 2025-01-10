{ ... }: {
  boot.loader.efi = {
    canTouchEfiVariables = false;
  };

  boot.loader.grub = {
    enable = true;
    useOSProber = true;
    memtest86.enable = true;

    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    extraEntries = ''
      menuentry "Firmware setup" {
          fwsetup
      }
    '';
  };
}

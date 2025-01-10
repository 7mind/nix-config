{ pkgs, ... }: {
  boot = {
    tmp.useTmpfs = true;
    tmp.cleanOnBoot = true;
    kernel.sysctl = {
      "kernel.sysrq" = 1;
      "net.core.somaxconn" = 65536;
      "vm.dirty_writeback_centisecs" = 1500; # powertop advice
      "kernel.nmi_watchdog" = 0; # powertop advice
      "fs.inotify.max_user_watches" = 1048576;
      "kernel.perf_event_paranoid" = 1; # intellij profiler
      "kernel.kptr_restrict" = 0; # intellij profiler
    };
    kernelParams = [
      #"video=efifb:off"
      # "pcie_aspm=off" # spurious interrupt?.. https://forum.proxmox.com/threads/kernel-pcieport-0000-c0-03-1-pme-spurious-native-interrupt.101338/
      # "msr.allow_writes=on" # amd ?
    ];

    # TODO: we need to verify if that's completely safe or not
    extraModprobeConfig = ''
      options snd_hda_intel power_save=1
    '';

    kernelModules = [ "r8169" ];

    initrd = {
      kernelModules = [ "r8169" ];
      systemd = {
        enable = true;
        emergencyAccess = true;
        initrdBin = with pkgs; [
          busybox
        ];
      };
    };
  };


  security.pam = {
    loginLimits = [
      {
        domain = "*";
        item = "nofile";
        type = "hard";
        value = "524288";
      }
      {
        domain = "*";
        item = "nofile";
        type = "soft";
        value = "524288";
      }
    ];
  };

  powerManagement = {
    enable = true;
    scsiLinkPolicy = "med_power_with_dipm";
  };

  services.udev = {
    extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="pci", ATTR{power/control}="auto"
      ACTION=="add|change", SUBSYSTEM=="block", ATTR{device/power/control}="auto"
      ACTION=="add|change", SUBSYSTEM=="ata_port", ATTR{../../power/control}="auto"
    '';
  };


  environment = {
    enableDebugInfo = true;
  };


  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    cpu.amd.updateMicrocode = true;
  };

}

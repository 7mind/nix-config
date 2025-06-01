{ config, lib, pkgs, cfg-packages, ... }:

{
  options = {
    smind.kernel.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.kernel.sane-defaults.enable {
    boot = {
      kernelPackages = cfg-packages.linux-kernel;

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

    systemd.tmpfiles.rules = [
      "w /sys/kernel/mm/transparent_hugepage/enabled - - - - always"
      "w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise"
      "w /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 0"
    ];

    boot.kernel.sysctl = {
      "fs.file-max" = 2097152;
      "fs.nr_open" = 2097152;
    };

    hardware = {
      enableRedistributableFirmware = true;
      cpu.intel.updateMicrocode = config.smind.hw.cpu.isIntel;
      cpu.amd.updateMicrocode = config.smind.hw.cpu.isAmd;
    };
  };
}

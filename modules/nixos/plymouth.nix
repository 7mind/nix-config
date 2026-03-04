{ config, lib, pkgs, ... }:

let
  cfg = config.smind.desktop.plymouth;
in
{
  options.smind.desktop.plymouth = {
    enable = lib.mkEnableOption "Plymouth graphical boot splash";

    theme = lib.mkOption {
      type = lib.types.str;
      default = "bgrt";
      description = "Plymouth theme to use (bgrt = vendor logo with spinner)";
    };

    early-amdgpu = lib.mkEnableOption ''
      early amdgpu loading in initrd for Plymouth.
      Loads amdgpu in initrd and blacklists simpledrm to prevent it from claiming the framebuffer first
    '' // { default = cfg.enable && config.smind.hw.amd.gpu.enable; };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.plymouth.enable = true;
      boot.plymouth.theme = cfg.theme;
      boot.consoleLogLevel = 3;
      boot.initrd.verbose = false;
      boot.kernelParams = [ "quiet" "splash" ];
    }

    (lib.mkIf cfg.early-amdgpu {
      boot.initrd.kernelModules = [ "amdgpu" ];
      hardware.amdgpu.initrd.enable = true;
      boot.kernelParams = [ "initcall_blacklist=simpledrm_platform_driver_init" ];
    })
  ]);
}

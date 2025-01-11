{ config, lib, ... }:

{
  options = {
    smind.hm.firefox.no-tabbar = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.firefox.no-tabbar {
    programs.firefox.profiles.main.userChrome = ''
      #main-window[tabsintitlebar="true"]:not([extradragspace="true"]) #TabsToolbar > .toolbar-items {
        opacity: 0;
        pointer-events: none;
      }
      #main-window:not([tabsintitlebar="true"]) #TabsToolbar {
        visibility: collapse !important;
      }
      #sidebar-header {
        display: none;
      }
    '';
  };
}

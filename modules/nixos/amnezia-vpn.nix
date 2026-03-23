{ config, lib, ... }:

{
  options = {
    smind.net.amnezia-vpn.enable = lib.mkEnableOption "AmneziaVPN client";
  };

  config = lib.mkIf config.smind.net.amnezia-vpn.enable {
    programs.amnezia-vpn.enable = true;
  };
}

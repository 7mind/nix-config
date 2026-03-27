{ config, lib, pkgs, ... }:

let
  cfg = config.smind.net.wifi;
  busctl = "${pkgs.systemd}/bin/busctl";
  nmcli = "${pkgs.networkmanager}/bin/nmcli";
  logger = "${pkgs.util-linux}/bin/logger";
  gawk = "${pkgs.gawk}/bin/awk";
  gnused = "${pkgs.gnused}/bin/sed";
  gnugrep = "${pkgs.gnugrep}/bin/grep";
  tr = "${pkgs.coreutils}/bin/tr";

  wpaDbus = "fi.w1.wpa_supplicant1";
  wpaRoot = "/fi/w1/wpa_supplicant1";
in
{
  options.smind.net.wifi = {
    disableFT = lib.mkEnableOption ''
      Disable 802.11r Fast Transition (FT) for WiFi connections.
      Works around drivers that fail FT key installation
      (e.g., MediaTek MT7925, Qualcomm ath12k on certain kernels).
      Uses a NetworkManager dispatcher to strip FT-PSK/FT-SAE/FT-EAP
      from wpa_supplicant key management via D-Bus after connection
    '';

    disableBSSTransition = lib.mkEnableOption ''
      Disable 802.11v BSS Transition Management.
      Prevents access points from forcefully steering the client
      to other APs via WNM Disassociation Imminent frames.
      Sets bss_transition=0 in wpa_supplicant config
    '';
  };

  config = lib.mkIf (cfg.disableFT || cfg.disableBSSTransition) {
    assertions = [
      {
        assertion = config.networking.networkmanager.enable;
        message = "smind.net.wifi.disableFT/disableBSSTransition require NetworkManager";
      }
      {
        assertion = config.networking.networkmanager.wifi.backend == "wpa_supplicant";
        message = "smind.net.wifi.disableFT/disableBSSTransition require wpa_supplicant backend";
      }
    ];

    # Disable 802.11v at the wpa_supplicant config level
    networking.wireless.extraConfig = lib.mkIf cfg.disableBSSTransition ''
      bss_transition=0
    '';

    networking.networkmanager.dispatcherScripts = lib.mkIf cfg.disableFT [
      {
        type = "basic";
        source = pkgs.writeScript "wifi-roaming-quirks" ''
          #!${pkgs.bash}/bin/bash
          IFACE="$1"
          ACTION="$2"

          case "$ACTION" in
            up) ;;
            *) exit 0 ;;
          esac

          # Only act on wifi interfaces
          if ! ${nmcli} -t -f DEVICE,TYPE device status 2>/dev/null | ${gnugrep} -q "^$IFACE:wifi$"; then
            exit 0
          fi

          # Resolve wpa_supplicant D-Bus paths for this interface
          IFACE_PATH=$(${busctl} call ${wpaDbus} ${wpaRoot} \
            ${wpaDbus} GetInterface s "$IFACE" 2>/dev/null \
            | ${gawk} '{print $2}' | ${tr} -d '"')

          if [ -z "$IFACE_PATH" ]; then
            ${logger} -t wifi-roaming-quirks "Could not find wpa_supplicant interface for $IFACE"
            exit 0
          fi

          NETWORK_PATH=$(${busctl} get-property ${wpaDbus} "$IFACE_PATH" \
            ${wpaDbus}.Interface CurrentNetwork 2>/dev/null \
            | ${gawk} '{print $2}' | ${tr} -d '"')

          if [ -z "$NETWORK_PATH" ] || [ "$NETWORK_PATH" = "/" ]; then
            ${logger} -t wifi-roaming-quirks "No current network on $IFACE"
            exit 0
          fi

          # Read current key_mgmt from network properties
          KEY_MGMT=$(${busctl} get-property ${wpaDbus} "$NETWORK_PATH" \
            ${wpaDbus}.Network Properties 2>/dev/null \
            | ${gnugrep} -oP '"key_mgmt" s "\K[^"]+')

          if [ -z "$KEY_MGMT" ]; then
            ${logger} -t wifi-roaming-quirks "Could not read key_mgmt for $IFACE"
            exit 0
          fi

          # Strip all FT key management methods
          NEW_KEY_MGMT=$(echo "$KEY_MGMT" \
            | ${gnused} 's/FT-EAP-SHA384//g; s/FT-SAE//g; s/FT-PSK//g; s/FT-EAP//g; s/  */ /g; s/^ //; s/ $//')

          if [ "$KEY_MGMT" = "$NEW_KEY_MGMT" ]; then
            exit 0
          fi

          if [ -z "$NEW_KEY_MGMT" ]; then
            ${logger} -t wifi-roaming-quirks "Refusing to set empty key_mgmt on $IFACE (was: $KEY_MGMT)"
            exit 0
          fi

          # Write stripped key_mgmt back via D-Bus Properties.Set
          if ${busctl} call ${wpaDbus} "$NETWORK_PATH" \
            org.freedesktop.DBus.Properties Set ssv \
            "${wpaDbus}.Network" "Properties" \
            "a{sv}" 1 "key_mgmt" "s" "$NEW_KEY_MGMT" 2>/dev/null; then
            ${logger} -t wifi-roaming-quirks "Disabled FT on $IFACE: $KEY_MGMT -> $NEW_KEY_MGMT"
          else
            ${logger} -t wifi-roaming-quirks "Failed to set key_mgmt on $IFACE via D-Bus"
          fi
        '';
      }
    ];
  };
}

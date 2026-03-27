{ config, lib, pkgs, ... }:

let
  cfg = config.smind.net.wifi;
  wpa_cli = "${pkgs.wpa_supplicant}/bin/wpa_cli";
  nmcli = "${pkgs.networkmanager}/bin/nmcli";
  logger = "${pkgs.util-linux}/bin/logger";
  gawk = "${pkgs.gawk}/bin/awk";
  gnused = "${pkgs.gnused}/bin/sed";
  gnugrep = "${pkgs.gnugrep}/bin/grep";
in
{
  options.smind.net.wifi = {
    disableFT = lib.mkEnableOption ''
      Disable 802.11r Fast Transition (FT) for WiFi connections.
      Works around drivers that fail FT key installation
      (e.g., MediaTek MT7925, Qualcomm ath12k on certain kernels).
      Uses a NetworkManager dispatcher to strip FT-PSK/FT-SAE/FT-EAP
      from wpa_supplicant key management after connection
    '';

    disableBSSTransition = lib.mkEnableOption ''
      Disable 802.11v BSS Transition Management.
      Prevents access points from forcefully steering the client
      to other APs via WNM Disassociation Imminent frames
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

    networking.networkmanager.dispatcherScripts = [
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

          ${lib.optionalString cfg.disableBSSTransition ''
            # Disable 802.11v BSS Transition Management - prevents AP-initiated forced roaming
            ${wpa_cli} -i "$IFACE" SET bss_transition 0 2>/dev/null \
              && ${logger} -t wifi-roaming-quirks "Disabled BSS Transition (802.11v) on $IFACE" \
              || true
          ''}

          ${lib.optionalString cfg.disableFT ''
            # Disable 802.11r Fast Transition by stripping FT key management methods.
            # wpa_supplicant uses the network block's key_mgmt during roaming;
            # removing FT variants forces regular (non-FT) reassociation.
            NET_ID=$(${wpa_cli} -i "$IFACE" list_networks 2>/dev/null \
              | ${gnugrep} CURRENT \
              | ${gawk} '{print $1}')

            if [ -n "$NET_ID" ]; then
              KEY_MGMT=$(${wpa_cli} -i "$IFACE" get_network "$NET_ID" key_mgmt 2>/dev/null)
              NEW_KEY_MGMT=$(echo "$KEY_MGMT" | ${gnused} 's/FT-PSK//g; s/FT-SAE//g; s/FT-EAP-SHA384//g; s/FT-EAP//g; s/  */ /g; s/^ //; s/ $//')

              if [ "$KEY_MGMT" != "$NEW_KEY_MGMT" ] && [ -n "$NEW_KEY_MGMT" ]; then
                ${wpa_cli} -i "$IFACE" set_network "$NET_ID" key_mgmt "$NEW_KEY_MGMT" 2>/dev/null \
                  && ${logger} -t wifi-roaming-quirks "Disabled FT on $IFACE network $NET_ID: $KEY_MGMT -> $NEW_KEY_MGMT" \
                  || ${logger} -t wifi-roaming-quirks "Failed to disable FT on $IFACE network $NET_ID"
              fi
            fi
          ''}
        '';
      }
    ];
  };
}

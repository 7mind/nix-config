{ config, lib, pkgs, ... }:

let
  alsCfg = config.smind.desktop.gnome.ambient-light-sensor;

  # Script that bridges iio-sensor-proxy to GNOME Shell brightness
  alsBrightnessScript = pkgs.writeShellScript "als-brightness-bridge" ''
    set -euo pipefail

    # Map lux to brightness (0.0 - 1.0)
    # Adjust these thresholds to your preference
    lux_to_brightness() {
      local lux=$1
      if (( $(echo "$lux < 5" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.15"
      elif (( $(echo "$lux < 20" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.25"
      elif (( $(echo "$lux < 50" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.35"
      elif (( $(echo "$lux < 100" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.50"
      elif (( $(echo "$lux < 300" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.65"
      elif (( $(echo "$lux < 500" | ${pkgs.bc}/bin/bc -l) )); then
        echo "0.80"
      else
        echo "1.0"
      fi
    }

    last_brightness=""

    while true; do
      # Get light level from sensor proxy
      lux=$(${pkgs.glib}/bin/gdbus call --system \
        --dest net.hadess.SensorProxy \
        --object-path /net/hadess/SensorProxy \
        --method org.freedesktop.DBus.Properties.Get \
        net.hadess.SensorProxy LightLevel 2>/dev/null | \
        ${pkgs.gnugrep}/bin/grep -oP '[\d.]+' | head -1)

      if [ -n "$lux" ]; then
        brightness=$(lux_to_brightness "$lux")

        # Only update if brightness changed
        if [ "$brightness" != "$last_brightness" ]; then
          ${pkgs.glib}/bin/gdbus call --session \
            --dest org.gnome.Shell \
            --object-path /org/gnome/Shell/Brightness \
            --method org.gnome.Shell.Brightness.SetAutoBrightnessTarget \
            "$brightness" >/dev/null 2>&1 || true
          last_brightness="$brightness"
        fi
      fi

      sleep 2
    done
  '';
in
{
  config = lib.mkIf (config.smind.desktop.gnome.enable && alsCfg.enable) {
    # Systemd user service to bridge ALS to GNOME Shell brightness
    # Workaround for gsd-power not calling SetAutoBrightnessTarget in GNOME 49
    systemd.user.services.als-brightness-bridge = {
      description = "Ambient Light Sensor to GNOME Shell Brightness Bridge";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${alsBrightnessScript}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}

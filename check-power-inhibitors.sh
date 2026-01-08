#!/usr/bin/env bash
echo "=== Logind power key settings ==="
grep -i power /etc/systemd/logind.conf 2>/dev/null || echo "(no logind.conf overrides)"
cat /etc/systemd/logind.conf.d/*.conf 2>/dev/null || echo "(no logind.conf.d files)"

echo -e "\n=== Current inhibitors ==="
systemd-inhibit --list

echo -e "\n=== GNOME power-button-action setting ==="
gsettings get org.gnome.settings-daemon.plugins.power power-button-action 2>/dev/null || echo "gsettings not available"

echo -e "\n=== dconf power settings ==="
dconf read /org/gnome/settings-daemon/plugins/power/power-button-action 2>/dev/null || echo "dconf not available"

echo -e "\n=== System dconf database ==="
cat /etc/dconf/db/local.d/* 2>/dev/null | grep -A5 -i power || echo "(no local dconf db or no power settings)"

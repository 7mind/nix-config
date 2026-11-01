# Jabridge

Jabridge is installed alongside `jabracli` by the Linux desktop defaults on
x86_64 and aarch64. The defaults install and enable its systemd user daemon;
NixOS also installs its device-access rules. It is not supported on macOS.

```bash
nix build .#jabridge
jabridge --version
systemctl --user status jabridge.service
jabridge
```

App self-updates and imperative `jabridge setup` are disabled using upstream's
package-maintainer build flags. Update the pinned package through Nix instead.
Device firmware updates remain available subject to upstream model support;
`dfu-util` is included, but firmware paths requiring Jabra's proprietary `jfwu`
still need an authorized vendor tool supplied separately.

Standalone Home Manager installs the app and user service, but cannot install
host udev rules. On a NixOS host, add the package to `services.udev.packages`;
on other Linux hosts, have the administrator install the packaged
`lib/udev/rules.d/70-jabridge.rules`. Reconnect the device after applying rules.
Access is granted to the active local desktop session, not every user.

If `jabridge setup` was used previously, move aside its unmanaged
`~/.config/systemd/user/jabridge.service` before applying this configuration
(Home Manager will otherwise report a file conflict). Then reload/restart the
user service so its version matches the packaged client. Do not run setup again.

These changes are declarative defaults, not a system activation. Hardware and
firmware operation still require validation with the actual device.

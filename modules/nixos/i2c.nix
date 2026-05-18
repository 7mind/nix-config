{ config, lib, ... }:

# Unconditionally enable kernel i2c-dev + the /dev/i2c-* group ACL on
# every Linux host. The userspace cost is a `i2c-dev` modprobe and a
# udev rule; both are inert if no I²C controller exists or is bound to
# a driver, so this is safe to ship on headless servers as well as
# laptops. The host owner (per `smind.host.owner`) is added to the
# `i2c` group so they can talk to userspace I²C tools (`i2c-tools`,
# `i2cdetect`, sensor / EEPROM / display utilities) without sudo.

{
  hardware.i2c.enable = true;

  # `smind.host.owner` is nullable; only wire the group on hosts that
  # actually declare an owner. The owner user itself is declared
  # elsewhere (users/*.nix); this attribute just merges "i2c" onto
  # their `extraGroups` via the NixOS module system's submodule merge.
  users.users = lib.optionalAttrs (config.smind.host.owner != null) {
    ${config.smind.host.owner}.extraGroups = [ "i2c" ];
  };
}

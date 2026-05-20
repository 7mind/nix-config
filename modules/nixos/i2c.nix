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

  # `smind.host.owner` is nullable, and on headless cloud nodes
  # (o1/o2) it names a logical owner that is *not* a real local user
  # account. Only merge "i2c" onto the owner's `extraGroups` when the
  # owner is also declared as a home-manager user on this host — that
  # is the signal that the owner has a real account here. Checking
  # `home-manager.users` instead of `config.users.users` avoids a
  # definition cycle (we contribute to the latter).
  users.users = lib.optionalAttrs
    (config.smind.host.owner != null
      && (config.home-manager.users or { }) ? ${config.smind.host.owner})
    {
      ${config.smind.host.owner}.extraGroups = [ "i2c" ];
    };
}

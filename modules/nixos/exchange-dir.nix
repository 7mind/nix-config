# Shared host directory for the yolo sandbox exchange protocol
# (ponygirls nix/pkg/yolo/llm-sandbox.sh).
#
# 1777, not 0777: the sticky bit lets any user create a subdirectory and stops
# every other user from unlinking it. Root ownership is required for the same
# reason /tmp is root-owned — the directory owner can unlink entries even when
# the sticky bit is set. /tmp is wiped on reboot, so a user-created parent
# would come back owned by whoever ran the sandbox first; tmpfiles recreates
# this as root:root. Per-user subdirectories are created by the sandbox wrapper.
{ ... }:
{
  systemd.tmpfiles.rules = [
    "d /tmp/exchange 1777 root root -"
  ];
}

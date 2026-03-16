#!/usr/bin/env bash
# Verify that the dedicated rootless-podman service user (podsvc-llm) is
# properly restricted: no privileged group memberships, no sudo, no read
# access to other users' homes, and that containers spawned through the
# podman-llm socket cannot escape via bind-mounts to read host secrets.
#
# Run as a regular user that is a member of the podsvc-llm group.
# Some checks need sudo to switch to podsvc-llm or read root-owned paths.

set -uo pipefail

readonly SVC_USER="podsvc-llm"
readonly SOCKET="/run/podman-llm/podman.sock"
readonly DOCKER_HOST_URI="unix://${SOCKET}"
readonly TEST_IMAGE="docker.io/library/alpine:latest"

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m: %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n=== %s ===\n' "$1"; }

# Resolve the invoking (real) user even when this script is run via sudo.
INVOKER="${SUDO_USER:-$USER}"
INVOKER_HOME="$(getent passwd "$INVOKER" | cut -d: -f6 || true)"

# ─── Service user sanity ──────────────────────────────────────────────────────
section "Service user identity"

if id "$SVC_USER" >/dev/null 2>&1; then
    pass "user $SVC_USER exists"
else
    fail "user $SVC_USER missing"
    exit 1
fi

# Must NOT be a member of any privileged or interactive group.
forbidden_groups=(wheel sudo root adm disk video kvm libvirtd networkmanager docker render input audio)
groups_list=" $(id -Gn "$SVC_USER") "
for g in "${forbidden_groups[@]}"; do
    if [[ "$groups_list" == *" $g "* ]]; then
        fail "$SVC_USER is in privileged group: $g"
    else
        pass "$SVC_USER is not in $g"
    fi
done

# ─── Privilege escalation ─────────────────────────────────────────────────────
section "podsvc cannot escalate"

# Only look for "may run" — that phrase appears when sudo lists real entries.
# The no-entries case prints "is not allowed to run sudo on this host", which
# contains "allowed to run" as a substring so that pattern can't be used here.
if sudo -nl -U "$SVC_USER" 2>/dev/null | grep -q "may run"; then
    fail "$SVC_USER has sudo entries"
else
    pass "$SVC_USER has no sudo entries"
fi

# ─── Filesystem read restrictions (direct, as podsvc-llm) ─────────────────────
section "podsvc cannot read sensitive host paths"

as_svc() { sudo -u "$SVC_USER" -- "$@"; }

check_no_read() {
    local target="$1"
    if as_svc test -r "$target" 2>/dev/null; then
        fail "$SVC_USER can read $target"
    else
        pass "$SVC_USER cannot read $target"
    fi
}

# Asserts that $SVC_USER cannot list the given directory. Skips if it does
# not exist so the test stays portable across hosts with different layouts.
check_no_list() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        printf '  skip: list check on %s (does not exist)\n' "$target"
        return
    fi
    if as_svc ls -A "$target" >/dev/null 2>&1; then
        fail "$SVC_USER can list $target"
    else
        pass "$SVC_USER cannot list $target"
    fi
}

check_no_read /etc/shadow
check_no_read /root

if [[ -n "$INVOKER_HOME" && "$INVOKER" != "$SVC_USER" && -e "$INVOKER_HOME" ]]; then
    # Cannot list the invoker's home (mode 0700 expected) nor any of the
    # directories that commonly hold personal data or credentials.
    check_no_list "$INVOKER_HOME"
    check_no_list "$INVOKER_HOME/Downloads"
    check_no_list "$INVOKER_HOME/.config"
    check_no_list "$INVOKER_HOME/.zsh_history"
    check_no_read "$INVOKER_HOME/.zsh_history"
    if [[ -e "$INVOKER_HOME/.ssh" ]]; then
        check_no_read "$INVOKER_HOME/.ssh"
    fi
fi

# ─── Socket sanity ────────────────────────────────────────────────────────────
section "Podman socket"

if [[ -S "$SOCKET" ]]; then
    pass "socket exists at $SOCKET"
else
    fail "socket missing at $SOCKET"
    exit 1
fi

sock_owner="$(stat -c '%U:%G' "$SOCKET")"
if [[ "$sock_owner" == "$SVC_USER:$SVC_USER" ]]; then
    pass "socket owned by $SVC_USER:$SVC_USER"
else
    fail "socket owner is $sock_owner (expected $SVC_USER:$SVC_USER)"
fi

sock_mode="$(stat -c '%a' "$SOCKET")"
if [[ "$sock_mode" == "660" ]]; then
    pass "socket mode is 0660"
else
    fail "socket mode is $sock_mode (expected 660)"
fi

# Parent dir must be 0750 so non-group users can't even traverse it.
dir_mode="$(stat -c '%a' "$(dirname "$SOCKET")")"
if [[ "$dir_mode" == "750" ]]; then
    pass "$(dirname "$SOCKET") is 0750"
else
    fail "$(dirname "$SOCKET") mode is $dir_mode (expected 750)"
fi

# ─── DOCKER_HOST environment ──────────────────────────────────────────────────
section "Environment variables"

# Read DOCKER_HOST from a fresh login shell to be independent of the caller's env.
env_docker_host="$(bash -lc 'printf "%s" "${DOCKER_HOST:-}"' 2>/dev/null || true)"
if [[ "$env_docker_host" == "$DOCKER_HOST_URI" ]]; then
    pass "DOCKER_HOST is set to $DOCKER_HOST_URI in login shells"
else
    fail "DOCKER_HOST in login shell is '$env_docker_host' (expected $DOCKER_HOST_URI)"
fi

env_container_host="$(bash -lc 'printf "%s" "${CONTAINER_HOST:-}"' 2>/dev/null || true)"
if [[ "$env_container_host" == "$DOCKER_HOST_URI" ]]; then
    pass "CONTAINER_HOST is set to $DOCKER_HOST_URI in login shells"
else
    fail "CONTAINER_HOST in login shell is '$env_container_host' (expected $DOCKER_HOST_URI)"
fi

# ─── Socket reachable from invoker ────────────────────────────────────────────
section "docker CLI connectivity"

export DOCKER_HOST="$DOCKER_HOST_URI"

if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI not found in PATH"
    exit 1
fi

if docker_err="$(docker version 2>&1 >/dev/null)"; then
    pass "docker version succeeds"
else
    # Disambiguate between the common failure causes so the operator knows
    # where to look instead of chasing a red herring.
    reason="docker version failed: ${docker_err:0:200}"
    if [[ " $(id -Gn) " != *" $SVC_USER "* ]]; then
        reason="$reason | caller $(id -un) is NOT in '$SVC_USER' group — re-login after enrolling"
    elif [[ ! -S "$SOCKET" ]]; then
        reason="$reason | socket file $SOCKET does not exist"
    elif [[ "$docker_err" == *"connection refused"* || "$docker_err" == *"No such device"* ]]; then
        reason="$reason | socket exists but nothing is listening — check 'systemctl --user --machine=${SVC_USER}@ status podman-llm.socket podman-llm.service'"
    fi
    fail "$reason"
    exit 1
fi

# Confirm we are in fact talking to the podsvc-llm rootless instance.
# Note: RemoteSocket.Path reports the URI including the unix:// scheme.
remote_info="$(docker info --format '{{.Host.Security.Rootless}} {{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
if [[ "$remote_info" == "true ${DOCKER_HOST_URI}" ]]; then
    pass "docker info confirms rootless mode at $DOCKER_HOST_URI"
else
    fail "docker info reports unexpected: '$remote_info'"
fi

# ─── Container bind-mount escape attempts ────────────────────────────────────
# Two distinct failure modes can block a malicious bind-mount escape; we
# assert on the specific one expected for each case rather than a loose
# "exit non-zero OR no output" check:
#
#   1. Mount refused by podman at start time (docker exit 125, stderr contains
#      "permission denied", usually "statfs <path>: permission denied"). This
#      happens when podsvc-llm can't even statfs the source, which is the case
#      for any path nested inside another user's home dir (mode 0700).
#
#   2. Mount succeeds, runtime denied inside the container (docker exit 0,
#      inner command prints "Permission denied" and exits 1). This happens
#      when the source can be statfs'd but the effective UID in the container
#      (container root → podsvc-llm on host) lacks read/write permission on
#      the actual inode.
#
# Both are security-positive, but they're triggered by different OS-level
# mechanisms and should be asserted separately.

section "Container cannot read host secrets via bind mount"

# Pre-pull so test failures are about access, not network/pull errors.
if ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    printf '  pulling %s ...\n' "$TEST_IMAGE"
    docker pull "$TEST_IMAGE" >/dev/null 2>&1 || {
        fail "could not pull $TEST_IMAGE"
        exit 1
    }
fi

# Shared utility: extract "INNER_EXIT=N" (last occurrence) from output.
extract_inner_exit() {
    printf '%s' "$1" | sed -n 's/.*INNER_EXIT=\([0-9]*\).*/\1/p' | tail -1
}

# Assert: bind mount succeeds, container starts, but the in-container command
# is denied by UNIX permissions on the mapped UID (podsvc-llm).
#   expected: docker exit 0, output contains "Permission denied", INNER_EXIT=1
assert_runtime_read_denied() {
    local label="$1" src="$2" dst="$3" cmd="$4"
    if [[ ! -e "$src" ]]; then
        printf '  skip: %s (source %s missing)\n' "$label" "$src"
        return
    fi
    local output rc=0
    output="$(docker run --rm --user 0:0 -v "${src}:${dst}:ro" "$TEST_IMAGE" \
        sh -c "${cmd}; echo INNER_EXIT=\$?" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "$label: expected docker exit 0 (mount+run OK), got $rc — output: ${output:0:160}"
        return
    fi
    if ! printf '%s' "$output" | grep -q "Permission denied"; then
        fail "$label: expected 'Permission denied' in output, got: ${output:0:200}"
        return
    fi
    local inner
    inner="$(extract_inner_exit "$output")"
    if [[ "$inner" != "1" ]]; then
        fail "$label: expected INNER_EXIT=1, got '${inner:-<none>}'"
        return
    fi
    pass "$label: runtime denied (docker=0, INNER_EXIT=1, 'Permission denied')"
}

# Assert: podman refuses to start the container because it can't statfs the
# mount source (parent dir not traversable by podsvc-llm).
#   expected: docker exit 125, output contains "permission denied"
assert_mount_refused() {
    local label="$1" src="$2" dst="$3"
    if [[ ! -e "$src" ]]; then
        printf '  skip: %s (source %s missing)\n' "$label" "$src"
        return
    fi
    local output rc=0
    output="$(docker run --rm --user 0:0 -v "${src}:${dst}:ro" "$TEST_IMAGE" true 2>&1)" || rc=$?
    if [[ $rc -ne 125 ]]; then
        fail "$label: expected docker exit 125 (mount refused), got $rc — output: ${output:0:200}"
        return
    fi
    if ! printf '%s' "$output" | grep -qi "permission denied"; then
        fail "$label: expected 'permission denied' in podman error, got: ${output:0:200}"
        return
    fi
    pass "$label: mount refused by podman (docker=125, 'permission denied')"
}

# Runtime-denied reads: mount succeeds, inner read is blocked by UNIX perms.
assert_runtime_read_denied "/etc/shadow" /etc/shadow /host_shadow "cat /host_shadow"
assert_runtime_read_denied "/etc/sudoers" /etc/sudoers /host_sudoers "cat /host_sudoers"
assert_runtime_read_denied "/root" /root /host_root "ls -A /host_root"
# /etc/ssh is 0755 so mount and dir-listing work, but the host private keys
# (mode 0600 root:root) cannot be read.
assert_runtime_read_denied "/etc/ssh host keys" /etc/ssh /host_etc_ssh \
    "cat /host_etc_ssh/ssh_host_*_key"
# /var/lib/private is 0700 root:root; parent /var/lib is 0755 so statfs works.
assert_runtime_read_denied "/var/lib/private" /var/lib/private /host_var_private \
    "ls -A /host_var_private"

if [[ -n "$INVOKER_HOME" && "$INVOKER" != "$SVC_USER" ]]; then
    # /home is 0755 but /home/$user is 0700 — the mount of the home dir
    # itself is allowed but reads inside are denied at runtime.
    assert_runtime_read_denied "$INVOKER \$HOME" "$INVOKER_HOME" /host_home \
        "ls -A /host_home"

    # Anything *nested* inside /home/$user can't even be statfs'd by
    # podsvc-llm, so podman refuses the mount before the container starts.
    [[ -d "$INVOKER_HOME/.ssh"       ]] && assert_mount_refused "$INVOKER/.ssh"       "$INVOKER_HOME/.ssh"       /host_ssh
    [[ -d "$INVOKER_HOME/.gnupg"     ]] && assert_mount_refused "$INVOKER/.gnupg"     "$INVOKER_HOME/.gnupg"     /host_gnupg
    [[ -d "$INVOKER_HOME/Downloads"  ]] && assert_mount_refused "$INVOKER/Downloads"  "$INVOKER_HOME/Downloads"  /host_downloads
    [[ -d "$INVOKER_HOME/.config"    ]] && assert_mount_refused "$INVOKER/.config"    "$INVOKER_HOME/.config"    /host_config
    [[ -f "$INVOKER_HOME/.zsh_history" ]] && assert_mount_refused "$INVOKER/.zsh_history" "$INVOKER_HOME/.zsh_history" /host_zsh_history
fi

# ─── Container bind-mount write attempts ─────────────────────────────────────
section "Container cannot write to sensitive host dirs via bind mount"

# Assert: read-write bind mount succeeds, but a runtime write is denied by
# UNIX perms. Sanity-checks the host filesystem afterwards to make sure no
# sentinel file leaked through.
#   expected: docker exit 0, 'Permission denied', INNER_EXIT=1, no host file.
assert_runtime_write_denied() {
    local label="$1" src="$2" dst="$3"
    if [[ ! -d "$src" ]]; then
        printf '  skip: %s (source %s not an existing directory)\n' "$label" "$src"
        return
    fi
    local name=".podsvc-llm-write-probe.$$"
    local host_sentinel="${src}/${name}"
    local output rc=0
    output="$(docker run --rm --user 0:0 -v "${src}:${dst}" "$TEST_IMAGE" \
        sh -c "touch ${dst}/${name} 2>&1; echo INNER_EXIT=\$?" 2>&1)" || rc=$?
    # Host-side truth first: if the sentinel landed, it's a hard fail.
    if [[ -e "$host_sentinel" ]]; then
        fail "$label write: sentinel landed on host at $host_sentinel"
        rm -f "$host_sentinel" 2>/dev/null \
            || sudo rm -f "$host_sentinel" 2>/dev/null \
            || true
        return
    fi
    if [[ $rc -ne 0 ]]; then
        fail "$label write: expected docker exit 0 (mount OK), got $rc — output: ${output:0:160}"
        return
    fi
    if ! printf '%s' "$output" | grep -q "Permission denied"; then
        fail "$label write: expected 'Permission denied' in output, got: ${output:0:200}"
        return
    fi
    local inner
    inner="$(extract_inner_exit "$output")"
    if [[ "$inner" != "1" ]]; then
        fail "$label write: expected INNER_EXIT=1, got '${inner:-<none>}'"
        return
    fi
    pass "$label write: runtime denied (docker=0, INNER_EXIT=1, no host sentinel)"
}

assert_runtime_write_denied "/etc" /etc /host_etc
assert_runtime_write_denied "/root" /root /host_root
assert_runtime_write_denied "/var/lib" /var/lib /host_varlib

if [[ -n "$INVOKER_HOME" && "$INVOKER" != "$SVC_USER" ]]; then
    assert_runtime_write_denied "$INVOKER \$HOME" "$INVOKER_HOME" /host_home
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
section "Summary"
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

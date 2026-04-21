#!/usr/bin/env bash
# resock: probe for a working ssh-agent socket and print a shell-evalable
# `export SSH_AUTH_SOCK=...` line.
#
# Typical use (via `eval` so the parent shell picks up the change):
#
#   eval "$(resock)"                # keep-if-alive, verbose
#   eval "$(resock --quiet)"        # keep-if-alive, silent (for scripts)
#   eval "$(resock --force)"        # rescan even if current socket works
#   eval "$(resock --clean-dead)"   # also rm dead forwarded sockets
#
# Probe order on mismatch:
#   1. Forwarded sockets (/tmp/ssh-*/agent.*, ~/.ssh/agent/*), newest first.
#   2. Local agents ($XDG_RUNTIME_DIR/gcr/ssh, $XDG_RUNTIME_DIR/ssh-agent).
#
# The key design point: if the *current* $SSH_AUTH_SOCK is alive, we keep it.
# Picking any-working-candidate without that check was the old behavior and
# it silently replaced working forwarded sockets with whatever responded
# first (often gcr, which answers `ssh-add -l` with a different key set).
#
# Exit codes:
#   0 — found (or kept) a working agent; the export line is on stdout.
#   1 — no working agent found; nothing on stdout.
#   2 — usage error.

set -u

force=false
clean_dead=false
quiet=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)      force=true;      shift ;;
        --clean-dead) clean_dead=true; shift ;;
        --quiet|-q)   quiet=true;      shift ;;
        -h|--help)
            sed -n '2,/^$/{/^#/{s/^# \?//p}}' "$0"
            exit 0
            ;;
        *)
            printf 'resock: unknown flag: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

log() {
    [[ "$quiet" == true ]] || printf 'resock: %s\n' "$*" >&2
}

probe() {
    # returns 0 iff the socket responds to ssh-add -l (rc 0 = keys loaded,
    # rc 1 = empty but alive, rc 2 = can't connect).
    local s="$1" rc
    [[ -S "$s" ]] || return 1
    SSH_AUTH_SOCK="$s" timeout 1 ssh-add -l >/dev/null 2>&1
    rc=$?
    (( rc != 2 ))
}

old_sock="${SSH_AUTH_SOCK:-}"

if [[ "$force" != true && -n "$old_sock" ]] && probe "$old_sock"; then
    log "keeping current SSH_AUTH_SOCK -> $old_sock"
    printf 'export SSH_AUTH_SOCK=%q\n' "$old_sock"
    exit 0
fi

runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
declare -a candidates=()

# Forwarded sockets from ssh -A, newest first.
while IFS= read -r sock; do
    [[ -n "$sock" && -S "$sock" ]] && candidates+=("$sock")
done < <(ls -t /tmp/ssh-*/agent.* "$HOME"/.ssh/agent/* 2>/dev/null || true)

# Local agents (gcr from gnome-keyring / standalone ssh-agent).
for sock in "$runtime_dir/gcr/ssh" "$runtime_dir/ssh-agent"; do
    [[ -S "$sock" ]] && candidates+=("$sock")
done

log "probing ${#candidates[@]} candidate socket(s) (was: ${old_sock:-<unset>})"
for sock in "${candidates[@]}"; do
    if probe "$sock"; then
        log "alive: $sock"
        printf 'export SSH_AUTH_SOCK=%q\n' "$sock"
        exit 0
    fi
    log "dead: $sock"
    if [[ "$clean_dead" == true ]]; then
        rm -f -- "$sock"
    fi
done

log "no working ssh-agent found (was ${old_sock:-<unset>})"
exit 1

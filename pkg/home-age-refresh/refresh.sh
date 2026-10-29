fail() {
    echo "Error: user secret refresh: $*" >&2
    exit 1
}

trusted_directory() {
    [[ ! -L "$1" && -d "$1" && $(stat -c %u -- "$1") == 0 ]] || fail "untrusted directory: $1"
    (( (8#$(stat -c %a -- "$1") & 0022) == 0 )) || fail "writable directory: $1"
}

[[ $# == 0 && -e /etc/NIXOS && $EUID == 0 ]] || fail "run this generation's helper with sudo on NixOS"
uid=$(id -u -- "$username")
[[ ${SUDO_USER:-} == "$username" && ${SUDO_UID:-} == "$uid" && $uid -ge 1000 ]] || fail "invoking user does not match this generation"
identity=/etc/ssh/ssh_host_ed25519_key
[[ ! -L "$identity" && -f "$identity" && -r "$identity" && $(stat -c %u -- "$identity") == 0 ]] || fail "host identity is missing, unreadable or untrusted"
trusted_directory /run/nixos
lock=/run/nixos/switch-to-configuration.lock
[[ ! -L "$lock" ]] || fail "symlinked switch lock"
if [[ -e "$lock" ]]; then
    [[ -f "$lock" && $(stat -c %u -- "$lock") == 0 ]] || fail "untrusted switch lock"
    (( (8#$(stat -c %a -- "$lock") & 0022) == 0 )) || fail "writable switch lock"
fi
exec 9>>"$lock"
flock -n 9 || fail "system switch or secret refresh in progress; retry after it finishes"

trusted_directory /run/agenix.d
[[ -L /run/agenix && $(stat -c %u /run/agenix) == 0 ]] || fail "unsupported agenix link"
generation=$(readlink /run/agenix)
[[ $generation =~ ^/run/agenix\.d/[0-9]+$ ]] || fail "unsupported agenix generation"
trusted_directory "$generation"
for i in "${!files[@]}"; do
    relative=${destinations[$i]}
    [[ $relative != */* || ${relative%/*} == "$username" ]] || fail "unsupported namespace: $relative"
    [[ ${relative##*/} =~ ^[a-zA-Z0-9_.-]+$ && ${relative##*/} != . && ${relative##*/} != .. ]] || fail "invalid destination: $relative"
    [[ ${modes[$i]} =~ ^0?[0-7]{3}$ ]] || fail "invalid file mode"
    target="$generation/$relative"
    trusted_directory "$(dirname "$target")"
    [[ ! -L "$target" ]] || fail "symlinked destination: $relative"
    if [[ -e "$target" ]]; then
        [[ -f "$target" && $(stat -c %u -- "$target") == "$uid" ]] || fail "destination owner/type mismatch: $relative"
    fi
done

umask 077
stage=$(mktemp -d "$generation/.hm-age.XXXXXXXX")
phase=decryption
trap 'status=$?; rm -rf -- "$stage"; if (( status != 0 )); then echo "Error: user secret refresh failed during $phase; published files are not rolled back" >&2; fi' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for i in "${!files[@]}"; do
    age --decrypt -i "$identity" -o "$stage/$i" "${files[$i]}"
done
phase=permissions
for i in "${!files[@]}"; do
    chown -- "$uid:${groups[$i]}" "$stage/$i"
    chmod -- "${modes[$i]}" "$stage/$i"
done
phase=publication
for i in "${!files[@]}"; do
    mv -fT -- "$stage/$i" "$generation/${destinations[$i]}"
done

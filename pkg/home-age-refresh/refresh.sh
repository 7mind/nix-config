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
namespace=
declare -A destinations_seen=()
for i in "${!files[@]}"; do
    relative=${destinations[$i]}
    [[ $relative != */* || ${relative%/*} == "$username" ]] || fail "unsupported namespace: $relative"
    [[ ${relative##*/} =~ ^[a-zA-Z0-9_.-]+$ && ${relative##*/} != . && ${relative##*/} != .. ]] || fail "invalid destination: $relative"
    [[ ${modes[$i]} =~ ^0?[0-7]{3}$ ]] || fail "invalid file mode"
    [[ -z ${destinations_seen[$relative]:-} ]] || fail "duplicate destination: $relative"
    destinations_seen[$relative]=present
    target="$generation/$relative"
    parent=$(dirname "$target")
    if [[ "$parent" == "$generation/$username" && ! -e "$parent" && ! -L "$parent" ]]; then
        namespace=$parent
    else
        trusted_directory "$parent"
    fi
    [[ ! -L "$target" ]] || fail "symlinked destination: $relative"
    if [[ -e "$target" ]]; then
        [[ -f "$target" && $(stat -c %u -- "$target") == "$uid" ]] || fail "destination owner/type mismatch: $relative"
    fi
done

umask 077
stage=$(mktemp -d "$generation/.hm-age.XXXXXXXX")
phase=decryption
created_namespace=
published=false
cleanup() {
    status=$?
    rm -rf -- "$stage"
    if [[ -n "$created_namespace" && "$published" == false ]]; then
        if [[ ! -L "$created_namespace" && -d "$created_namespace" && $(stat -c %u -- "$created_namespace") == 0 ]] &&
            (( (8#$(stat -c %a -- "$created_namespace") & 0022) == 0 )); then
            rmdir -- "$created_namespace" || echo "Error: user secret refresh could not remove its empty namespace" >&2
        else
            echo "Error: user secret refresh left an untrusted namespace untouched" >&2
        fi
    fi
    if (( status != 0 )); then
        echo "Error: user secret refresh failed during $phase; published files are not rolled back" >&2
    fi
}
trap cleanup EXIT
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
phase=namespace
if [[ -n "$namespace" ]]; then
    mkdir -m 0755 -- "$namespace"
    created_namespace=$namespace
    chown 0:0 -- "$namespace"
    trusted_directory "$namespace"
fi
phase=publication
for i in "${!files[@]}"; do
    mv -fT -- "$stage/$i" "$generation/${destinations[$i]}"
    published=true
done

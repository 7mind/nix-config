set -euo pipefail

generation="$1"
integration_directory="$2"
nixos_marker="$3"
username="$(id -un)"
export HOME_MANAGER_BACKUP_EXT=hmbak

if [[ -e "$nixos_marker" ]]; then
    integration_file="$integration_directory/$username"
    if [[ ! -r "$integration_file" ]]; then
        echo "Error: install persistent Home Manager integration with a full NixOS switch first" >&2
        exit 1
    fi
    read -r profile < "$integration_file"
    exec @profileCommand@ switch "$profile" "$generation/nixos-generation"
fi

exec "$generation/activate"

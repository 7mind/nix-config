set -euo pipefail

action="$1"
profile="$2"
exec 9>>"${profile}.switch-lock"
flock 9

case "$action" in
    system)
        request="$(readlink -e "$3")"
        read -r system_generation system_action generation < "$request"
        marker="${profile}.system-generation"
        request_marker="${profile}.system-request"
        if [[ ! -e "$profile" || ! -L "$marker" || "$(readlink "$marker")" != "$system_generation" ]] ||
            [[ "$system_action" != boot && ( ! -L "$request_marker" || "$(readlink "$request_marker")" != "$request" ) ]]; then
            nix-env --profile "$profile" --set "$(readlink -e "$generation")"
            ln -sfn "$system_generation" "$marker"
            ln -sfn "$request" "$request_marker"
        fi
        ;;
    switch)
        nix-env --profile "$profile" --set "$(readlink -e "$3")"
        ;;
    *)
        echo "Error: unknown Home Manager profile action '$action'" >&2
        exit 1
        ;;
esac
"$profile/activate" --driver-version 1 9>&-

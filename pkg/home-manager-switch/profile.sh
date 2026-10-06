set -euo pipefail

action="$1"
profile="$2"
exec 9>>"${profile}.switch-lock"
flock 9

case "$action" in
    system)
        request="$(readlink -e "$3")"
        {
            read -r system_generation
            read -r system_action
            read -r generation
        } < "$request"
        generation="$(readlink -e "$generation")"
        marker="${profile}.system-generation"
        request_marker="${profile}.system-request"
        if [[ -e "$profile" && -L "$marker" && "$(readlink "$marker")" == "$system_generation" ]] &&
            [[ "$system_action" == boot || ( -L "$request_marker" && "$(readlink "$request_marker")" == "$request" ) ]]; then
            exit 0
        fi
        nix-env --profile "$profile" --set "$generation"
        ln -sfn "$system_generation" "$marker"
        ln -sfn "$request" "$request_marker"
        ;;
    switch)
        generation="$(readlink -e "$3")"
        nix-env --profile "$profile" --set "$generation"
        "$profile/activate" --driver-version 1 9>&-
        ;;
    activate)
        "$profile/activate" --driver-version 1 9>&-
        ;;
    *)
        echo "Error: unknown Home Manager profile action '$action'" >&2
        exit 1
        ;;
esac

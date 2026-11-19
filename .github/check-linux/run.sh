set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
revision=$(git rev-parse --verify HEAD)
if [[ $revision != "${GITHUB_SHA:-$revision}" ]]; then
  printf 'Checked-out revision %s differs from GITHUB_SHA %s\n' "$revision" "$GITHUB_SHA" >&2
  exit 1
fi
project="git+$(python3 -c 'from pathlib import Path; print(Path.cwd().as_uri())')?ref=HEAD&rev=$revision"
if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
  project+='&shallow=1'
fi
isolated=(home-age home-age-runtime home-configurations)

case ${1:-} in
  materialize)
    for name in "${isolated[@]}"; do
      nix eval --no-write-lock-file --raw "$project#checks.x86_64-linux.$name.drvPath"
      printf '\n'
    done
    nix eval --no-write-lock-file --raw "$project#nixosConfigurations.testbench.config.system.build.toplevel.drvPath"
    ;;
  check)
    directory=$(mktemp -d)
    trap 'rm -rf -- "$directory"' EXIT
    cp .github/check-linux/flake.nix "$directory/flake.nix"
    for name in '' "${isolated[@]}"; do
      jq -n --arg project "$project" --arg selected "$name" --args \
        '{ $project, $selected, isolated: $ARGS.positional }' "${isolated[@]}" > "$directory/partition.json"
      printf 'Checking %s\n' "${name:-remaining flake outputs}"
      nix flake check --no-write-lock-file --no-build "path:$directory"
    done
    ;;
  *) printf 'Usage: bash %s {materialize|check}\n' "$0" >&2; exit 2 ;;
esac

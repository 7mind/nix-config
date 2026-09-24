#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
flake_dir="$(cd -- "$script_dir/.." && pwd)"
setup="$flake_dir/setup"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "FAKE_NIX_CWD=%s\n" "$PWD"' \
  'printf "FAKE_NIX_ARG=%s\n" "$@"' \
  > "$test_dir/nix"
chmod +x "$test_dir/nix"

outside="$(env -u NIX_CONFIG_DEV_SHELL PATH="$test_dir:$PATH" "$setup" --help)"
[[ "$outside" == *'FAKE_NIX_ARG=develop'* ]] || {
  echo 'FAIL: setup did not enter the flake dev shell' >&2
  exit 1
}
[[ "$outside" == *'FAKE_NIX_ARG=.?submodules=1'* ]] || {
  echo 'FAIL: setup did not use its own submodule-aware flake' >&2
  exit 1
}
[[ "$outside" == *"FAKE_NIX_CWD=$flake_dir"* ]] || {
  echo 'FAIL: setup did not enter its flake directory' >&2
  exit 1
}

inside="$(NIX_CONFIG_DEV_SHELL=1 PATH="$test_dir:$PATH" "$setup" --help)"
[[ "$inside" == Usage:* && "$inside" != *FAKE_NIX_ARG* ]] || {
  echo 'FAIL: setup re-entered the dev shell despite its marker' >&2
  exit 1
}

echo 'setup dev-shell entry tests passed'

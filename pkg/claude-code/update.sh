#!/usr/bin/env bash
# Update claude-code to the latest version published on npm.
#
# Bumps the `version` field and refreshes the four per-platform SRI hashes in
# package.nix. Run from anywhere — the script edits the package.nix that sits
# next to it.
#
# Keep this in sync with the manual instructions in package.nix. If you change
# one, change the other.

set -euo pipefail

cd "$(dirname "$0")"
pkg_nix="package.nix"

current=$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)";.*/\1/p' "$pkg_nix" | head -n1)
latest=$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r .version)

echo "current: $current"
echo "latest:  $latest"

if [[ "$current" == "$latest" ]]; then
  echo "already up to date"
  exit 0
fi

platforms=(claude-code-linux-x64 claude-code-linux-arm64 claude-code-darwin-x64 claude-code-darwin-arm64)

# Fetch all hashes up-front so a mid-run failure does not leave package.nix in
# a half-updated state.
declare -A new_hashes
for pkg in "${platforms[@]}"; do
  url="https://registry.npmjs.org/@anthropic-ai/${pkg}/-/${pkg}-${latest}.tgz"
  echo "fetching ${pkg}..."
  sha=$(nix-prefetch-url --type sha256 --unpack "$url" 2>/dev/null)
  new_hashes[$pkg]=$(nix hash convert --hash-algo sha256 --to sri "$sha")
  printf '  %s\n' "${new_hashes[$pkg]}"
done

sed -i -E "s|^([[:space:]]*version[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${latest}\2|" "$pkg_nix"

for pkg in "${platforms[@]}"; do
  new_sri="${new_hashes[$pkg]}"
  old_sri=$(grep -A1 "pkg = \"$pkg\";" "$pkg_nix" | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -n1)
  if [[ -z "$old_sri" ]]; then
    echo "could not find existing hash for $pkg in $pkg_nix" >&2
    exit 1
  fi
  if [[ "$old_sri" != "$new_sri" ]]; then
    sed -i "s|${old_sri}|${new_sri}|" "$pkg_nix"
  fi
done

echo
echo "updated $pkg_nix to $latest"
echo "next: ./verify-configs --verbose <hostname>"

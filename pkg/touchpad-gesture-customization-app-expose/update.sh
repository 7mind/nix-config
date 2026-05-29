#!/usr/bin/env bash
# Update touchpad-gesture-customization-app-expose to the latest upstream commit.
#
# Bumps `version` (0-unstable-YYYY-MM-DD from the commit date), `rev`, the source
# `hash`, and `npmDepsHash` in default.nix. Run from anywhere — the script edits
# the default.nix that sits next to it.
#
# Keep this in sync with the manual instructions in default.nix. If you change
# one, change the other.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
nix_file="$script_dir/default.nix"
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
pkg_subdir=${script_dir#"$repo_root"/}

owner=7mind
repo=touchpad-gesture-customization-app-expose

current_rev=$(sed -nE 's/^[[:space:]]*rev[[:space:]]*=[[:space:]]*"([^"]+)";.*/\1/p' "$nix_file" | head -n1)

echo "fetching latest commit for ${owner}/${repo}..."
latest_rev=$(git ls-remote "https://github.com/${owner}/${repo}.git" HEAD | awk '{print $1}')

echo "current rev: $current_rev"
echo "latest rev:  $latest_rev"

if [[ "$current_rev" == "$latest_rev" ]]; then
  echo "already up to date"
  exit 0
fi

# Commit date -> version string 0-unstable-YYYY-MM-DD.
commit_date=$(curl -fsSL "https://api.github.com/repos/${owner}/${repo}/commits/${latest_rev}" \
  | jq -r '.commit.committer.date' | cut -dT -f1)
new_version="0-unstable-${commit_date}"
echo "new version: $new_version"

# Source hash: fetchFromGitHub hashes the unpacked source tree (NAR), which
# `nix-prefetch-url --unpack` reproduces exactly.
echo "prefetching source..."
src_sha=$(nix-prefetch-url --type sha256 --unpack \
  "https://github.com/${owner}/${repo}/archive/${latest_rev}.tar.gz" 2>/dev/null)
src_hash=$(nix hash convert --hash-algo sha256 --to sri "$src_sha")
echo "  src hash: $src_hash"

# Apply version, rev, source hash. The `hash =` match is anchored so it does not
# touch the `npmDepsHash =` line.
sed -i -E "s|^([[:space:]]*version[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${new_version}\2|" "$nix_file"
sed -i -E "s|^([[:space:]]*rev[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${latest_rev}\2|" "$nix_file"
sed -i -E "s|^([[:space:]]*hash[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${src_hash}\2|" "$nix_file"

# npmDepsHash: the fixed-output npm-deps derivation has no offline prefetch tool
# here, so we use the fake-hash dance — set a sentinel, build, and read the real
# hash from the FOD mismatch error. The source `hash` is already correct above,
# so the build proceeds past the source fetch and fails on the npm deps.
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
sed -i -E "s|^([[:space:]]*npmDepsHash[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${fake_hash}\2|" "$nix_file"

build_expr='let flake = builtins.getFlake "git+file://'"${repo_root}"'?submodules=1"; in flake.pkgs.${builtins.currentSystem}.callPackage ./'"${pkg_subdir}"'/default.nix { }'

echo "computing npmDepsHash (building until the npm-deps FOD fails)..."
build_log=$(cd "$repo_root" && nix build --impure --no-link \
  --option substituters https://cache.nixos.org \
  --expr "$build_expr" 2>&1 || true)

npm_hash=$(printf '%s\n' "$build_log" \
  | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' \
  | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -n1)

if [[ -z "$npm_hash" ]]; then
  echo "could not extract npmDepsHash from the build output:" >&2
  printf '%s\n' "$build_log" >&2
  echo >&2
  echo "npmDepsHash left as the sentinel ${fake_hash} — fix manually." >&2
  exit 1
fi

echo "  npmDepsHash: $npm_hash"
sed -i -E "s|^([[:space:]]*npmDepsHash[[:space:]]*=[[:space:]]*\")[^\"]+(\";)|\1${npm_hash}\2|" "$nix_file"

echo
echo "updated $nix_file to $new_version ($latest_rev)"
echo "next: ./verify-configs --verbose <hostname>"

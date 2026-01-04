#!/usr/bin/env bash
# Regenerates cargo-lock.patch and updates hash for fractal-tray
# Run this when updating fractal or ksni versions

set -uo pipefail  # removed -e to allow continuing after expected failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "Script dir: $SCRIPT_DIR"
echo "Repo root: $REPO_ROOT"

# Get fractal source path from nixpkgs
echo "Getting fractal source..."
FRACTAL_SRC=$(nix-build '<nixpkgs>' -A fractal.src --no-out-link 2>/dev/null)
if [ -z "$FRACTAL_SRC" ]; then
    echo "ERROR: Could not get fractal source"
    exit 1
fi
echo "Using fractal source: $FRACTAL_SRC"

# Copy source to work directory
cp -r "$FRACTAL_SRC"/* "$WORK_DIR/"
chmod -R u+w "$WORK_DIR"
cd "$WORK_DIR"

# Add ksni dependency using cargo add (preserves existing deps)
echo "Adding ksni dependency..."
nix-shell -p cargo rustc --run "cargo add ksni@0.3"

# Create Cargo.toml patch
echo "Creating cargo.patch..."
diff -u "$FRACTAL_SRC/Cargo.toml" Cargo.toml | \
  sed '1s|^--- .*|--- a/Cargo.toml|; 2s|^+++ .*|+++ b/Cargo.toml|' \
  > "$SCRIPT_DIR/cargo.patch" || true

# Create Cargo.lock patch with proper headers for patch -p1
echo "Creating cargo-lock.patch..."
diff -u "$FRACTAL_SRC/Cargo.lock" Cargo.lock | \
  sed '1s|^--- .*|--- a/Cargo.lock|; 2s|^+++ .*|+++ b/Cargo.lock|' \
  > "$SCRIPT_DIR/cargo-lock.patch" || true

# Set fake hash first to trigger hash calculation
echo "Setting fake hash to trigger recalculation..."
sed -i 's|hash = "sha256-[^"]*";|hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";|' "$SCRIPT_DIR/default.nix"

# Build to get correct hash
echo "Calculating cargo vendor hash (this will fail with hash mismatch)..."
echo "Running: nix build in $REPO_ROOT"
echo "(This may take a while - look for hash mismatch in output below)"
echo ""
cd "$REPO_ROOT"

# Use temp file for build output and show progress in real-time
BUILD_LOG=$(mktemp)

# Run build with verbose logging, capturing to file while showing output
# Build just the fractal-tray package using callPackage
nix-build --no-out-link -E "with import <nixpkgs> {}; callPackage $SCRIPT_DIR/default.nix {}" 2>&1 | tee "$BUILD_LOG" || true

BUILD_OUTPUT=$(cat "$BUILD_LOG")
rm -f "$BUILD_LOG"

echo ""
echo "Build completed (with expected failure)"
echo "Searching for hash in output..."

# Try multiple patterns to extract hash
NEW_HASH=$(echo "$BUILD_OUTPUT" | grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' | head -1)

if [ -z "$NEW_HASH" ]; then
    # Try simpler pattern
    NEW_HASH=$(echo "$BUILD_OUTPUT" | grep -oE 'sha256-[A-Za-z0-9+/]{43}=' | tail -1)
fi

if [ -n "$NEW_HASH" ]; then
    echo "Found hash: $NEW_HASH"
    echo "Updating default.nix..."
    sed -i "s|hash = \"sha256-[^\"]*\";|hash = \"$NEW_HASH\";|" "$SCRIPT_DIR/default.nix"
    echo ""
    echo "Done! Hash updated. Rebuild with:"
    echo "  sudo nixos-rebuild switch --flake .#pavel-fw"
else
    echo ""
    echo "Could not extract hash automatically."
    echo ""
    echo "Build output (last 50 lines):"
    echo "=============================="
    echo "$BUILD_OUTPUT" | tail -50
    echo ""
    echo "Look for 'got: sha256-...' and update default.nix manually."
fi

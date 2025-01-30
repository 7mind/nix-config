#!/usr/bin/env bash

set -xe

for file in *.json; do
    new_name="${file%.*}.nix"
    nix eval --impure --expr "builtins.fromJSON (builtins.readFile ./${file})"  > $new_name
    nix run nixpkgs#nixfmt-classic $new_name
done

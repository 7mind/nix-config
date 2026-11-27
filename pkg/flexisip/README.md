# Flexisip (Nix package)

Belledonne Communications Flexisip 2.6.2, built against:

- nixpkgs `linphonePackages` (bctoolbox, ortp, belr, belle-sip, mediastreamer2, liblinphone, …)
- Vendored sofia-sip pin `5c6c07e` (Flexisip 2.6.2 submodule; GitLab-only, under `vendor/`).
  The separate conference package still uses `02b6544`.
- XXE-patched libxsd pin `a2ca5f36` (GitLab-only submodule; fetched at build time, unchanged since 2.6.1).

Upstream’s flake is a **dev shell only** (x86_64, no package output). This package is the deployable unit.

## Build

```bash
nix build --impure --expr '
let pkgs = (builtins.getFlake (toString ./.)).pkgs.${builtins.currentSystem};
in pkgs.callPackage ./pkg/flexisip/default.nix { }
'
```

Or via the repo overlay: `pkgs.flexisip` on any host that imports `modules/nixos/overlay.nix`.

## Notes

- **MWI**: Flexisip 2.6.2's B2BUA uses the aggregate Message Waiting Indication counters available in the pinned nixpkgs Linphone SDK 5.5.36; SDK 5.5.13 lacks these APIs.
- **Recording / echo**: not provided by Flexisip itself. See `modules/nixos/flexisip.nix`.
- **Refreshing sofia-sip vendor**: the pin is only on `gitlab.linphone.org`. From a host that can reach it:

  ```bash
  rev=5c6c07ea2814958aac00e02158d57097e080b158
  name=bc-sofia-sip-5c6c07e
  tmp=$(mktemp -d)
  curl -fL -o "$tmp/sofia-pin.tgz" \
    "https://gitlab.linphone.org/BC/public/external/sofia-sip/-/archive/$rev/sofia-sip-$rev.tar.gz"
  (umask 002; mkdir "$tmp/$name"
   tar --no-same-permissions -xzf "$tmp/sofia-pin.tgz" -C "$tmp/$name" --strip-components=1)
  tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - -C "$tmp" "$name" | gzip -n > "pkg/flexisip/vendor/$name.tar.gz"
  rm -rf "$tmp"
  ```

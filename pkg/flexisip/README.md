# Flexisip (Nix package)

Belledonne Communications Flexisip 2.6.1, built against:

- nixpkgs `linphonePackages` (bctoolbox, ortp, belr, belle-sip, mediastreamer2, liblinphone, …)
- Vendored sofia-sip pin `02b6544` (Flexisip 2.6.x submodule; GitLab-only, under `vendor/`)
- Flexisip 2.6.1 XXE-patched libxsd pin `a2ca5f36` (GitLab-only submodule; fetched at build time)

Upstream’s flake is a **dev shell only** (x86_64, no package output). This package is the deployable unit.

## Build

```bash
nix build --impure --expr '
let pkgs = import (builtins.getFlake "nixpkgs") { system = builtins.currentSystem; };
in pkgs.callPackage ./pkg/flexisip/default.nix { linphonePackages = pkgs.linphonePackages; }
'
```

Or via the repo overlay: `pkgs.flexisip` on any host that imports `modules/nixos/overlay.nix`.

## Notes

- **MWI stubs**: two B2BUA methods that need newer liblinphone MWI APIs than nixpkgs 5.4.85 are stubbed (household PBX does not use MWI).
- **Recording / echo**: not provided by Flexisip itself. See `modules/nixos/flexisip.nix`.
- **Refreshing sofia-sip vendor**: the pin is only on `gitlab.linphone.org`. From a host that can reach it:

  ```bash
  curl -fL -o /tmp/sofia-pin.tgz \
    "https://gitlab.linphone.org/BC/public/external/sofia-sip/-/archive/02b65440585a0553827967f889ea0c34bdb5538d/sofia-sip-02b65440585a0553827967f889ea0c34bdb5538d.tar.gz"
  mkdir -p /tmp/sofia-repack/bc-sofia-sip-02b6544
  tar xzf /tmp/sofia-pin.tgz -C /tmp/sofia-repack/bc-sofia-sip-02b6544 --strip-components=1
  tar czf pkg/flexisip/vendor/bc-sofia-sip-02b6544.tar.gz -C /tmp/sofia-repack bc-sofia-sip-02b6544
  ```

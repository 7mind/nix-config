{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hyprwhspr = {
      url = "github:goodroot/hyprwhspr/v1.49.2";
      flake = false;
    };

    flake-utils.url = "github:numtide/flake-utils";

    ponygirls = {
      url = "github:7mind/ponygirls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    f4 = {
      url = "github:unxed/f4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

    crane.url = "github:ipetkov/crane";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    mqtt-controller = {
      url = "github:pshirshov/mqtt-controller";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.crane.follows = "crane";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pylontech = {
      url = "github:pshirshov/mqtt-pylontech";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    qendercore-adapter = {
      url = "github:pshirshov/mqtt-qendercore";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    mqtt-spc = {
      url = "github:pshirshov/mqtt-spc";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ecoflow-mqtt = {
      url = "github:pshirshov/ecoflow-mqtt";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-apple-fonts = {
      # Fork of braindefender/nix-apple-fonts fixing evaluation against nixpkgs
      # >= 25.11 (removed lib.fold, reached via snowfall-lib). Upstream PR:
      # https://github.com/braindefender/nix-apple-fonts/pull/1 — switch back once merged.
      url = "github:autopeasant/nix-apple-fonts";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin/master"; # master for nixpkgs-unstable
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/LnL7/nix-darwin/issues/214
    mac-app-util = {
      url = "github:hraban/mac-app-util";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    vicinae-extensions = {
      url = "github:vicinaehq/extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    browservice = {
      url = "github:pshirshov/browservice";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    kanata-switcher = {
      url = "github:7mind/kanata-switcher/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    classic-app-switcher = {
      url = "github:neko-kai/classic-app-switcher";
      flake = false;
    };

    touchpad-gesture-customization-app-expose = {
      url = "github:7mind/touchpad-gesture-customization-app-expose";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Track `develop`: the latest release (= `main`) predates nixpkgs 26.11's
    # removal of `stdenv.hostPlatform.linux-kernel`, so its bootloader module
    # aborts evaluation with `attribute 'linux-kernel' missing` / `buildDTBs
    # missing` on our unstable (26.11) nixpkgs. `develop` carries the 26.11
    # compatibility fixes (PRs #198, #199). Move back to a pinned release once
    # one ships with those changes.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop";

    fractal = {
      url = "git+https://gitlab.gnome.org/pshirshov/fractal.git?ref=wip/full-patchset";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # zimt — multi-model image-gen REPL + web UI, pre-built per backend
    # (xpu/cuda/rocm/cpu). Used on vm (Arc Pro B70, XPU). Deliberately does
    # NOT follow our nixpkgs: it vendors pip wheels (torch+IPEX, diffusers,
    # transformers, fastapi …) whose compatibility window tracks zimt's own
    # pinned nixpkgs; drifting breaks the wheel build.
    zimt = {
      url = "github:pshirshov/zimt";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # Legacy github:7mind/cq input removed. Replacement is ../cq4; not wired yet.

    # Resilient WAN-bonding tunnel with adaptive FEC, used by modules/nixos/wanbond.nix.
    wanbond = {
      url = "github:7mind/wanbond/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = inputs: (import ./lib/mk-flake.nix) {
    inherit inputs;
    self = inputs.self;
  };
}

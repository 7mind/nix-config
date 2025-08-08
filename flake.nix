{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/staging-next";
    # nixpkgs.url = "github:LunNova/nixpkgs/rocm-update";

    flake-utils.url = "github:numtide/flake-utils";

    lanzaboote.url = "github:nix-community/lanzaboote/v0.4.1";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    smind = {
      url = "github:7mind/7mind-nix/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pylontech = {
      url = "github:pshirshov/python-pylontech";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-apple-fonts = {
      url = "github:braindefender/nix-apple-fonts/6f1a4b74cb889c7bc28d378715c79b4d0b35f5b8";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/LnL7/nix-darwin/issues/214
    mac-app-util = {
      url = "github:hraban/mac-app-util";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs@{ self, ... }:
    let
      globals = import ./globals.nix;
      hosts-public = import ./hosts.nix;
      hosts-private = globals.import_if_exists_or ./private/hosts.nix ({ ... }: {
        nixos = [ ];
        darwin = [ ];
      });
      builders = {
        make-nixos-x86_64 = globals.make-nixos-x86_64 { inherit inputs; inherit self; };
        make-nixos-aarch64 = globals.make-nixos-aarch64 { inherit inputs; inherit self; };
        make-darwin-aarch64 = globals.make-darwin-aarch64 { inherit inputs; inherit self; };
      };
    in
    {
      inherit globals; # this makes this flake reusable by other flakes

      nixosConfigurations = builtins.listToAttrs ((hosts-public builders).nixos ++ (hosts-private builders).nixos);

      darwinConfigurations = builtins.listToAttrs ((hosts-public builders).darwin ++ (hosts-private builders).darwin);

      agenix-rekey = inputs.agenix-rekey.configure {
        userFlake = self;
        nixosConfigurations = self.nixosConfigurations // self.darwinConfigurations;
      };
    } // inputs.flake-utils.lib.eachDefaultSystem (system: rec {
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.agenix-rekey.overlays.default ];
      };
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          agenix-rekey
          nixfmt-classic
          # inputs.json2nix.packages."${system}".json2nix
        ];
      };
    });

}

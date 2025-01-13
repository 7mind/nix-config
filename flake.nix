{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    smind = {
      url = "github:7mind/7mind-nix/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-apple-fonts = {
      url = "github:braindefender/nix-apple-fonts/6f1a4b74cb889c7bc28d378715c79b4d0b35f5b8";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, ... }:
    let
      globals = import ./globals.nix;
      make-nixos-x86_64 = globals.make-nixos-x86_64 { inherit inputs; inherit self; };
    in
    {
      inherit globals; # this makes this flake reusable by other flakes

      nixosConfigurations = builtins.listToAttrs
        (map (item: item)
          [
            (make-nixos-x86_64 "pavel-am5")
          ]
        );
    };
}

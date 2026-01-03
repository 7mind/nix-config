{ pkgs, ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      # https://github.com/NixOS/nixpkgs/issues/474535
      # gemini-cli fails with nodejs 24, pin to nodejs_22
      gemini-cli = super.gemini-cli.override {
        nodejs = super.nodejs_22;
        buildNpmPackage = super.buildNpmPackage.override { nodejs = super.nodejs_22; };
      };
    })
  ];
}

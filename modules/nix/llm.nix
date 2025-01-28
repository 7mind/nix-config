{ pkgs, lib, config, ... }:
let
  pinPackage =
    { name
    , commit
    , sha256
    ,
    }:
    (import
      (builtins.fetchTarball {
        inherit sha256;
        url = "https://github.com/NixOS/nixpkgs/archive/${commit}.tar.gz";
      })
      { system = pkgs.system; }).${name};
in
{
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    services.ollama = {
      enable = true;
      # https://github.com/NixOS/nixpkgs/issues/375910
      package = pkgs.ollama-rocm;
      # package = (pinPackage {
      #   name = "ollama";
      #   commit = "d0169965cf1ce1cd68e50a63eabff7c8b8959743";
      #   sha256 = "sha256:1hh0p0p42yqrm69kqlxwzx30m7i7xqw9m8f224i3bm6wsj4dxm05";
      # });
      rocmOverrideGfx = "10.3.0";
      acceleration = "rocm";
    };

    services.tabby = {
      enable = true;
      acceleration = "rocm";
    };
  };

}

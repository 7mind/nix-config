{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ngspice
  ];
}

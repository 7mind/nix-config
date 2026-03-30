{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ngspice
    qucs-s
  ];
}

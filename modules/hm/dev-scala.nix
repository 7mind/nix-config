{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.dev.scala.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Scala/JVM development tools";
    };
  };

  config = lib.mkIf config.smind.hm.dev.scala.enable {
    home.sessionVariables = {
      COURSIER_PROGRESS = "false";
    };

    home.packages = with pkgs; [
      scalafmt
      scala-cli

      #ammonite
      # scala
      # sbt
      # mill
      # coursier
    ];

  };
}


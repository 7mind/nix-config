{
  state-version-nixpkgs = "25.05";
  state-version-hm = "25.05";

  cfg-packages = { inputs, pkgs, arch }: {
    jdk-main = pkgs.graalvm-ce;
  };
}

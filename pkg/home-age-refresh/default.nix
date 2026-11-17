{ writeShellApplication, coreutils, util-linux, age, jq }:
writeShellApplication {
  name = "refresh-user-secrets";
  runtimeInputs = [ coreutils util-linux age jq ];
  text = builtins.readFile ./refresh.sh;
}

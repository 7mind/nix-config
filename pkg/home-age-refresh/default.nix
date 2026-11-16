{ lib, writeShellApplication, coreutils, util-linux, age, username, secrets }:
writeShellApplication {
  name = "refresh-user-secrets";
  runtimeInputs = [ coreutils util-linux age ];
  text = ''
    username=${lib.escapeShellArg username}
    files=(${lib.escapeShellArgs (map (s: "${builtins.path { path = s.file; }}") secrets)})
    destinations=(${lib.escapeShellArgs (map (s: lib.removePrefix "/run/agenix/" s.path) secrets)})
    groups=(${lib.escapeShellArgs (map (s: s.group) secrets)})
    modes=(${lib.escapeShellArgs (map (s: s.mode) secrets)})
  '' + builtins.readFile ./refresh.sh;
}

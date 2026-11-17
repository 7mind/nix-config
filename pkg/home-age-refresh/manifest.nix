{ lib, writeText, secrets }:
writeText "home-age-refresh.json" (builtins.toJSON (map (secret: {
  file = "${builtins.path { path = secret.file; }}";
  destination = lib.removePrefix "/run/agenix/" secret.path;
  inherit (secret) group mode;
}) secrets))

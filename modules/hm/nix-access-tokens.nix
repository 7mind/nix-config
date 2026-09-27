{ config, lib, ... }:

let
  cfg = config.smind.hm.nix;
in
{
  options.smind.hm.nix.githubAccessTokenFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Runtime path of a file containing a GitHub token used to authenticate
      Nix's GitHub API requests (the `access-tokens` setting in nix.conf).
      At activation the token is read from this file and written to
      ''${xdg.configHome}/nix/nix.conf — this module fully manages that file —
      so the secret never enters the Nix store. Activation must be re-run
      after rotating the token. Set to null to disable.
    '';
  };

  config = lib.mkIf (cfg.githubAccessTokenFile != null) {
    home.activation.nix-github-access-token = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      tokenFile=${lib.escapeShellArg cfg.githubAccessTokenFile}
      confFile=${config.xdg.configHome}/nix/nix.conf
      if [[ -r "$tokenFile" && -s "$tokenFile" ]]; then
        umask 077
        mkdir -p "$(dirname "$confFile")"
        printf 'access-tokens = github.com=%s\n' "$(<"$tokenFile")" > "$confFile"
      else
        echo "smind.hm.nix.githubAccessTokenFile: '$tokenFile' is missing or unreadable, leaving '$confFile' unchanged" >&2
      fi
    '';
  };
}

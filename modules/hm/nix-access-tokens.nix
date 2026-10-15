{ config, lib, ... }:

let
  cfg = config.smind.hm.nix;
  managedNixConfig = config.nix.enable && config.nix.package != null;
  tokenConfigFile = "${config.xdg.configHome}/nix/${if managedNixConfig then "github-access-token.conf" else "nix.conf"}";
in
{
  options.smind.hm.nix.githubAccessTokenFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Runtime path of a file containing a GitHub token used to authenticate
      Nix's GitHub API requests (the `access-tokens` setting in nix.conf).
      At activation the token is read from this file and written to a private
      nix.conf fragment when Home Manager manages nix.conf, or to nix.conf
      otherwise, so the secret never enters the Nix store. Activation must be re-run
      after rotating the token. Set to null to disable.
    '';
  };

  config = lib.mkIf (cfg.githubAccessTokenFile != null) {
    nix.extraOptions = lib.mkIf managedNixConfig ''
      !include ${tokenConfigFile}
    '';
    home.activation.nix-github-access-token = lib.hm.dag.entryAfter [ "writeBoundary" "reloadSystemd" ] ''
      tokenFile=${lib.escapeShellArg cfg.githubAccessTokenFile}
      confFile=${lib.escapeShellArg tokenConfigFile}
      if [[ -r "$tokenFile" && -s "$tokenFile" ]]; then
        umask 077
        mkdir -p "$(dirname "$confFile")"
        printf 'access-tokens = github.com=%s\n' "$(<"$tokenFile")" > "$confFile"
        chmod 0600 "$confFile"
      else
        echo "smind.hm.nix.githubAccessTokenFile: '$tokenFile' is missing or unreadable, leaving '$confFile' unchanged" >&2
      fi
    '';
  };
}

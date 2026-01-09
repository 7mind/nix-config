{ config, lib, ... }:

let
  netDomain = config.networking.domain or null;
  netHostName = config.networking.hostName or null;
in
{
  options.smind.host = {
    owner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Primary owner/user of this host (e.g., 'pavel'). Used for loading user-specific secrets.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Host group for deployment purposes (e.g., 'pavel', 'infra'). Used by setup script.";
    };

    fqn = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fully qualified hostname for remote deployment (e.g., 'o1.7mind.io'). If null, uses local deployment.";
    };
  };

  config = {
    # Default group to owner if owner is set
    smind.host.group = lib.mkDefault (
      if config.smind.host.owner != null
      then config.smind.host.owner
      else "default"
    );

    # Default fqn from networking.hostName + networking.domain if domain is set
    smind.host.fqn = lib.mkDefault (
      if netDomain != null && netHostName != null
      then "${netHostName}.${netDomain}"
      else null
    );
  };
}

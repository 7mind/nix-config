{ config, lib, pkgs, cfg-const, ... }:

{
  options = {
    smind.hm.nushell.enable = lib.mkEnableOption "Nushell with custom configuration";
  };

  config = lib.mkIf config.smind.hm.nushell.enable {
    programs.nushell = {
      enable = true;
      extraConfig = ''
        let carapace_completer = {|spans|
          carapace $spans.0 nushell ...$spans | from json
        }

        $env.config = {
         show_banner: false,
         completions: {
         case_sensitive: false
         quick: true
         partial: true
         algorithm: "fuzzy"
         external: {
             enable: true
             max_results: 100
             completer: $carapace_completer
           }
         }
        }

        $env.PATH = ($env.PATH | split row (char esep) | append /usr/bin/env)
      '';

      plugins = with pkgs.nushellPlugins; [
        query
        gstat
      ];

      environmentVariables = config.home.sessionVariables;
    };

    programs.atuin.enableNushellIntegration = true;
    programs.carapace.enableNushellIntegration = true;
    programs.zoxide.enableNushellIntegration = true;
    programs.direnv.enableNushellIntegration = true;
    home.shell.enableNushellIntegration = true;
    programs.starship.enableNushellIntegration = true;

    home.packages = with pkgs; [
      nufmt
    ];
  };
}

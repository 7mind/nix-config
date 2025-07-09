{ config, lib, pkgs, cfg-const, ... }:

{
  options = {
    smind.hm.nushell.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.nushell.enable {
    programs.nushell = {
      enable = true;
      # The config.nu can be anywhere you want if you like to edit your Nushell with Nu
      # configFile.source = ./.../config.nu;
      # for editing directly to config.nu
      extraConfig = ''
        let carapace_completer = {|spans|
          carapace $spans.0 nushell ...$spans | from json
        }

        $env.config = {
         show_banner: false,
         completions: {
         case_sensitive: false # case-sensitive completions
         quick: true    # set to false to prevent auto-selecting completions
         partial: true    # set to false to prevent partial filling of the prompt
         algorithm: "fuzzy"    # prefix or fuzzy
         external: {
             # set to false to prevent nushell looking into $env.PATH to find more suggestions
             enable: true
             # set to lower can improve completion performance at the cost of omitting some options
             max_results: 100
             completer: $carapace_completer # check 'carapace_completer'
           }
         }
        }

        $env.PATH = ($env.PATH | split row (char esep) | append /usr/bin/env)
      '';

      # shellAliases = cfg-const.universal-aliases;

      plugins = with pkgs.nushellPlugins; [
        #net
        #units
        query
        gstat
        highlight
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

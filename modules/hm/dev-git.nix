{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.dev.git.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.dev.git.enable {
    home.packages = with pkgs; [ git-review tig lazygit ];

    programs.git = {
      enable = true;
      package = pkgs.gitFull;
      settings = {
        alias = {
          lg =
            "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
          ignore = "!gi() { curl -L -s https://www.gitignore.io/api/$@ ;}; gi";
          ignorej =
            "!gi() { curl -L -s https://www.gitignore.io/api/visualstudiocode,jetbrains+all,java,scala,sbt,maven,metals ;}; gi";
        };

        extraConfig = {
          credential.helper = "${pkgs.gitFull}/bin/git-credential-libsecret";

          core = {
            reloadindex = true;
            whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
            compression = 9;
            editor = "nano";
            untrackedcache = true;
            fsmonitor = true;
          };
          push = {
            default = "simple";
            autoSetupRemote = true;
          };
          pull = { ff = "only"; };

          branch.autosetuprebase = "always";

          receive.fsckObjects = true;
          status.submodulesummary = true;
          pack.packSizeLimit = "2g";
          fetch.prune = "false";
          rebase.autoStash = true;
          help.autocorrect = 3;
          init.defaultBranch = "main";
          mergetool.keepBackup = "false";

          sequence.editor = "${pkgs.git-interactive-rebase-tool}/bin/interactive-rebase-tool";
        };
      };
    };
  };
}

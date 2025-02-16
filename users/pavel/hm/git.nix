{ pkgs, lib, config, nixosConfig, ... }: {
  programs.git = {
    userName = "Pavel Shirshov";
    userEmail = "pshirshov@eml.cc";

    signing.signByDefault = false;
    signing.key = "${nixosConfig.age.secrets."id_ed25519.pub".path}";
    signing.format = "ssh";

    difftastic = {
      enable = true;
      background = "dark";
      color = "auto";
      display = "side-by-side";
    };

    extraConfig = {
      # diff.tool = "difftastic";
      # difftool.prompt = false;
      # pager.difftool = true;
      # "difftool \"difftastic\"".cmd = "difft $LOCAL $REMOTE";

      # # diff.tool = "vscode";
      # "difftool \"vscode\"".cmd = "code --wait --diff $LOCAL $REMOTE";
      # "difftool \"p4mergetool\"".cmd = "p4merge $LOCAL $REMOTE";

      merge.tool = "smerge";
      "mergetool \"vscode\"".cmd = "code --wait $MERGED";
      "mergetool \"smerge\"".cmd =
        ''cmd = smerge mergetool "$BASE" "$LOCAL" "$REMOTE" -o "$MERGED"'';

      #"mergetool \"p4mergetool\"".cmd =
      #  "p4merge $PWD/$BASE $PWD/$REMOTE $PWD/$LOCAL $PWD/$MERGED";
    };

  };

}

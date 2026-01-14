{ config, lib, pkgs, cfg-flakes, cfg-packages, cfg-meta, override_pkg, cfg-args, ... }:

{
  options = {
    smind.hm.vscodium.enable = lib.mkEnableOption "VSCodium with extensions and settings";

    smind.hm.vscodium.fontSize = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "VSCodium editor and terminal font size";
    };
  };

  config = lib.mkIf config.smind.hm.vscodium.enable {
    home.packages = with pkgs; [
    ];

    # sometimes vscodium borks extensions.json so it's better to make sure there is nothing before deployment
    home.activation.vscode-cleanup = config.lib.dag.entryBefore [ "writeBoundary" ] ''
      rm -f "${config.home.homeDirectory}/.vscode-oss/extensions/extensions.json"
    '';

    # force overwrite config files to prevent "would be clobbered" errors
    # Only needed on Linux where VSCodium may have existing config files
    home.file = lib.optionalAttrs cfg-meta.isLinux {
      "${config.xdg.configHome}/VSCodium/User/settings.json".force = true;
      "${config.xdg.configHome}/VSCodium/User/keybindings.json".force = true;
    };

    programs.vscode =
      {
        enable = true;
        package = override_pkg {
          pkg = pkgs.vscodium;
          path = "bin/codium";
          ld-libs = [ pkgs.icu pkgs.openssl ];
        };

        profiles.default.extensions = with pkgs.vscode-marketplace; with pkgs.vscode-extensions; [
          #github.github-vscode-theme

          codezombiech.gitignore

          mhutchie.git-graph
          donjayamanne.githistory

          # eamodio.gitlens # annoying

          scalameta.metals
          scala-lang.scala

          jnoortheen.nix-ide
          mkhl.direnv

          mads-hartmann.bash-ide-vscode

          dbaeumer.vscode-eslint

          ms-python.python

          #ms-vscode.powershell
          # ms-vscode.hexeditor
          # ms-azuretools.vscode-docker
          # ms-vscode.anycode # real extensions are not nixified

          ms-vscode.cmake-tools
          ms-vscode.makefile-tools

          pkgs.vscode-marketplace.anthropic.claude-code

          twxs.cmake

          # https://github.com/VSCodium/vscodium/blob/master/docs/index.md#proprietary-extensions
          # ms-vscode-remote.remote-wsl
          # ms-vscode-remote.remote-ssh

          # ms-dotnettools.csharp
          # ms-dotnettools.csdevkit
          # ms-dotnettools.vscode-dotnet-runtime

          redhat.vscode-xml
          redhat.vscode-yaml
          redhat.java

          ocamllabs.ocaml-platform

          septimalmind.baboon-vscode
          septimalmind.idealingua1
          pkgs.open-vsx.septimalmind.grandmaster-builds

          pkgs.open-vsx.jeanp413.open-remote-ssh
          pkgs.open-vsx.devmikeua.mikrotik-routeros-script

          # vscjava.vscode-java-pack
          # missing: anycode*,
          thenuprojectcontributors.vscode-nushell-lang
        ] ++ (if cfg-meta.isDarwin then [ ] else [
          ms-vscode.cpptools
        ]);

        profiles.default.userSettings = {
          "window.titleBarStyle" = "native";
          "workbench.startupEditor" = "newUntitledFile";
          "editor.fontSize" = config.smind.hm.vscodium.fontSize;
          "editor.fontFamily" =
            "'FiraMono Nerd Font', 'Fira Code Nerd Font Mono', 'Fira Code', monospace";
          "terminal.integrated.fontFamily" =
            "'Hack Nerd Font Mono', 'FiraMono Nerd Font', monospace";
          "editor.fontLigatures" = true;
          "editor.dragAndDrop" = false;
          "editor.wordWrap" = "on";
          "editor.renderWhitespace" = "trailing";
          "editor.find.autoFindInSelection" = "multiline";

          "files.autoSave" = "afterDelay";
          "files.autoSaveDelay" = 500;
          "files.exclude" = {
            "/.git" = true;
            "/.svn" = true;
            "/.hg" = true;
            "/CVS" = true;
            "/.DS_Store" = true;
            "/.history" = true;
            "/.github" = true;
            "/.vscode" = true;
            "*.aux" = true;
            "*.nav" = true;
            "*.out" = true;
            "*.snm" = true;
            "*.toc" = true;
            "**/node_modules" = true;
            "**/.direnv" = true;
            "**/.venv" = true;
          };
          #"explorer.excludeGitIgnore" = true;

          "files.insertFinalNewline" = true;
          "files.trimTrailingWhitespace" = true;
          "terminal.integrated.fontSize" = config.smind.hm.vscodium.fontSize;
          "editor.multiCursorModifier" = "ctrlCmd";

          "git.autofetch" = true;

          "window.restoreWindows" = "all";
          "window.menuBarVisibility" = "visible";
          "window.newWindowDimensions" = "offset";
          "window.enableMenuBarMnemonics" = false;
          "window.openFoldersInNewWindow" = "on";

          "workbench.colorCustomizations" = {
            "sideBar.background" = "#3c3f41";
            "editor.background" = "#293134";
            "editorGutter.background" = "#3f4b4e";
            "contrastBorder" = "#323232";
          };
          "workbench.colorTheme" = "Dark Modern";

          "workbench.settings.editor" = "json";
          "workbench.tree.indent" = 16;
          "workbench.editor.highlightModifiedTabs" = true;
          "workbench.settings.openDefaultSettings" = true;
          "workbench.iconTheme" = "vs-seti";
          "workbench.tree.enableStickyScroll" = false;
          "workbench.reduceMotion" = "on";

          "editor.cursorSmoothCaretAnimation" = "off";
          "editor.smoothScrolling" = true;
          "editor.matchBrackets" = "never";
          "editor.bracketPairColorization.enabled" = true;
          "editor.guides.bracketPairs" = "active";
          "editor.formatOnSave" = true;
          "editor.formatOnPaste" = false;
          "editor.stickyScroll.enabled" = false;

          "files.watcherExclude" = {
            "**/.git" = true;
            "**/.bloop" = true;
            "**/.metals" = true;
            "**/.ammonite" = true;
            "**/.direnv" = true;
            "**/target" = true;
          };

          "editor.inlineSuggest.enabled" = true;
          "security.workspace.trust.banner" = "always";
          "telemetry.enableTelemetry" = false;
          "telemetry.enableCrashReporter" = false;
          "security.workspace.trust.untrustedFiles" = "open";

          "docker.showStartPage" = false;



          # nix
          "nix.enableLanguageServer" = true;
          "nix.formatterPath" = "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt";
          "nix.serverPath" = "${pkgs.nixd}/bin/nixd";
          "nix.serverSettings" = {
            "nil" = {
              "formatting" = { "command" = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" ]; };
              "nix" = { "flake" = { autoArchive = true; autoEvalInputs = true; }; };
            };
            "nixd" = {
              "formatting" = {
                "command" = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" ];
              };
            };
          };
          "[nix]" = { };

          # scala
          "metals.enableIndentOnPaste" = true;
          "metals.enableSemanticHighlighting" = true;
          "metals.enableStripMarginOnTypeFormatting" = true;
          "metals.showInferredType" = true;
          "metals.showImplicitConversionsAndClasses" = false;
          "metals.showImplicitArguments" = false;
          "metals.javaHome" = "${pkgs.graalvmPackages.graalvm-ce}";
          "metals.serverVersion" = "${pkgs.metals.version}";

          "xml.java.home" = "${pkgs.graalvmPackages.graalvm-ce}";
          "xml.server.workDir" = "~/.cache/lemminx";

          "update.mode" = "none";

          "makefile.configureOnOpen" = true;

          "redhat.telemetry.enabled" = false;

          "java.configuration.runtimes" = [
            {
              "name" = "Main JDK";
              "path" = "${cfg-packages.jdk-main}";
              default = true;
            }
            # {
            #   "name" = "GraalVM 19 CE+JS";
            #   "path" = let graal-legacy = cfg-flakes.pkgs7mind.graalvm-legacy-packages; in "${graal-legacy.graalvm19-ce-js.out}";
            # }
          ];


          "direnv.restart.automatic" = true;
        };
      };

  };
}


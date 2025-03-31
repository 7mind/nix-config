{ config, lib, pkgs, cfg-flakes, cfg-packages, cfg-meta, override_pkg, ... }:

{
  options = {
    smind.hm.vscodium.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.vscodium.enable {
    home.packages = with pkgs; [
    ];

    # sometimes vscodium borks extensions.json so it's better to make sure there is nothing before deployment
    home.activation.vscode-extensions-cleanup = config.lib.dag.entryBefore [ "writeBoundary" ] ''
      echo >&2 "Removing vscodium extensions.json..."
      rm -f "${config.home.homeDirectory}/.vscode-oss/extensions/extensions.json"
    '';

    programs.vscode = {
      enable = true;
      package = override_pkg {
        pkg = pkgs.vscodium;
        path = "bin/codium";
        ld-libs = [ pkgs.icu pkgs.openssl ];
      };

      profiles.default.extensions = with pkgs.vscode-extensions; [
        github.github-vscode-theme

        codezombiech.gitignore

        mhutchie.git-graph
        donjayamanne.githistory
        eamodio.gitlens

        scalameta.metals
        scala-lang.scala

        jnoortheen.nix-ide
        mkhl.direnv
        # arrterian.nix-env-selector # legacy nix envs

        mads-hartmann.bash-ide-vscode

        dbaeumer.vscode-eslint

        # dart-code.dart-code
        # dart-code.flutter

        #ms-vscode.powershell
        ms-vscode.hexeditor

        ms-azuretools.vscode-docker
        ms-python.python

        # ms-vscode.anycode # real extensions are not nixified

        ms-vscode.cmake-tools
        ms-vscode.makefile-tools
        twxs.cmake

        # https://github.com/VSCodium/vscodium/blob/master/docs/index.md#proprietary-extensions
        # ms-vscode-remote.remote-wsl
        # ms-vscode-remote.remote-ssh

        ms-dotnettools.csharp
        ms-dotnettools.csdevkit
        ms-dotnettools.vscode-dotnet-runtime

        redhat.vscode-xml
        redhat.vscode-yaml
        redhat.java

        continue.continue
        rooveterinaryinc.roo-cline
        
        # vscjava.vscode-java-pack
        # missing: anycode*,
      ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
        {
          name = "baboon-vscode";
          publisher = "SeptimalMind";
          version = "0.0.7";
          sha256 = "sha256-ilRSjlYdfMGkDS6ROWxQZvhDXjm9BWM9qAm1i+oaRrc=";
        }
        {
          name = "idealingua1";
          publisher = "SeptimalMind";
          version = "0.0.5";
          sha256 = "sha256-9vxtMNTf7VCGwesjGD6oxxsKZzqCBRPRjBXRkA3U/SA=";
        }
      ] ++ (if cfg-meta.isDarwin then [ ] else [
        ms-vscode.cpptools
      ]);

      profiles.default.userSettings = {
        "window.titleBarStyle" = "native";
        "workbench.startupEditor" = "newUntitledFile";
        "editor.fontSize" = 14;
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
          "**/node_modules" = false;
        };
        "files.insertFinalNewline" = true;
        "files.trimTrailingWhitespace" = true;
        "terminal.integrated.fontSize" = 14;
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
        "workbench.colorTheme" = "GitHub Dark Dimmed";

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
        "nix.serverPath" = "${pkgs.nil}/bin/nil";
        "nix.serverSettings" = {
          "nil" = {
            "formatting" = { "command" = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" ]; };
            "nix" = { "flake" = { autoArchive = true; autoEvalInputs = true; }; };
          };
          "nixd" = {
            "eval" = { };
            "formatting" = {
              "command" = "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt";
            };
            "options" = {
              "enable" = true;
              "target" = {
                "args" = [ ];
                "installable" = "<flakeref>#nixosConfigurations.<name>.options";
              };
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
        "metals.javaHome" = "${pkgs.graalvm-ce}";
        "metals.serverVersion" = "${pkgs.metals.version}";

        "xml.java.home" = "${pkgs.graalvm-ce}";
        "xml.server.workDir" = "~/.cache/lemminx";

        "update.mode" = "none";

        "makefile.configureOnOpen" = true;

        "redhat.telemetry.enabled" = false;

        "java.configuration.runtimes" = let graal-legacy = cfg-flakes.pkgs7mind.graalvm-legacy-packages; in [
          {
            "name" = "Main JDK";
            "path" = "${cfg-packages.jdk-main}";
            default = true;
          }
          {
            "name" = "GraalVM 19 CE+JS";
            "path" = "${graal-legacy.graalvm19-ce-js.out}";
          }
        ];
      };
    };

  };
}


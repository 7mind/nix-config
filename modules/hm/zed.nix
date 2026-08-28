{ config, lib, pkgs, cfg-flakes, cfg-packages, cfg-meta, outerConfig, override_pkg, ... }:

let
  hasUserKeymaps = config.smind.hm.zed.userKeymaps != [ ];
in
{
  options = {
    smind.hm.zed.enable = lib.mkEnableOption "Zed editor with custom configuration";

    smind.hm.zed.uiFontSize = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "Zed UI font size";
    };

    smind.hm.zed.bufferFontSize = lib.mkOption {
      type = lib.types.int;
      default = 14;
      description = "Zed buffer/editor font size";
    };

    smind.hm.zed.terminalFontFamily = lib.mkOption {
      type = lib.types.str;
      default = outerConfig.smind.fonts.terminal;
      description = "Zed terminal font family";
    };

    smind.hm.zed.userKeymaps = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Zed keymaps (passed to programs.zed-editor.userKeymaps)";
    };

    smind.hm.zed.mutableConfig = lib.mkEnableOption "mutable Zed config (writable by Zed, not pinned by HM)";
  };

  config = lib.mkIf config.smind.hm.zed.enable (lib.mkMerge [
    (lib.mkIf (!config.smind.hm.zed.mutableConfig) {
      # force overwrite settings.json to prevent "would be clobbered" errors
      xdg.configFile."zed/settings.json".force = true;
    })

    {
      programs.zed-editor = {
        enable = true;

        mutableUserSettings = config.smind.hm.zed.mutableConfig;
        mutableUserKeymaps = config.smind.hm.zed.mutableConfig || !hasUserKeymaps;

        extensions = [
          "nix"
          "html"
          "toml"
          "dockerfile"
          "java"
          "git-firefly"
          "latex"
          "make"
          "xml"
          "swift"
          "lua"
          "csharp"
          "kotlin"
          "basher"
          "haskell"
          "ini"
          "scala"
          "pylsp"
          "python-refactoring"
        ];

        userSettings = {
          load_direnv = "direct";
          autosave = {
            after_delay = {
              milliseconds = 250;
            };
          };
          agent = {
            enabled = false;
          };
          collaboration_panel = {
            button = false;
          };
          notification_panel = {
            button = false;
          };
          show_call_status_icon = false;
          title_bar = {
            show_menus = true;
          };
          minimap = {
            show = "always";
          };
          telemetry = {
            diagnostics = false;
            metrics = false;
          };
          vim_mode = false;
          ui_font_size = config.smind.hm.zed.uiFontSize;
          buffer_font_size = config.smind.hm.zed.bufferFontSize;
          buffer_line_height = { custom = 1.2; };
          auto_update = false;
          buffer_font_family = "FiraMono Nerd Font";
          terminal = {
            font_family = config.smind.hm.zed.terminalFontFamily;
          };
          project_panel = {
            entry_spacing = "standard";
          };
          auto_signature_help = true;
          show_signature_help_after_edits = true;
          show_completions_on_input = true;
          show_completion_documentation = true;
          hover_popover_enabled = true;

          "scrollbar" = {
            "show" = "auto";
            "cursors" = true;
            "git_diff" = true;
            "search_results" = true;
            "selected_symbol" = true;
            "diagnostics" = "warning";
          };
          "gutter" = {
            "line_numbers" = true;
            "runnables" = true;
            "folds" = true;
          };

          lsp = {
            nixd = {
              binary = {
                path = "${pkgs.nixd}/bin/nixd";
              };
              settings = {
                formatting = {
                  command = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" ];
                };
              };
            };
            nil = {
              binary = {
                path = "${pkgs.nil}/bin/nil";
              };
              initialization_options = {
                formatting = {
                  command = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" ];
                };
              };
            };
            pylsp = {
              binary = {
                path = "${pkgs.python3Packages.python-lsp-server}/bin/pylsp";
              };
            };
            bash-language-server = {
              binary = {
                path = "${pkgs.bash-language-server}/bin/bash-language-server";
              };
            };
            metals = {
              binary = {
                path = "${pkgs.metals}/bin/metals";
              };
            };
            omnisharp = {
              binary = {
                path = "${pkgs.omnisharp-roslyn}/bin/OmniSharp";
              };
            };
            jdtls = {
              binary = {
                path = "${pkgs.jdt-language-server}/bin/jdtls";
              };
            };
          };

          languages = {
            Nix = {
              language_servers = [ "nixd" "!nil" ];
            };
            Scala = {
              tab_size = 2;
            };
          };
        };

        userKeymaps = config.smind.hm.zed.userKeymaps;

        extraPackages = with pkgs; [
          # Rust
          rustup
          tree-sitter
          nodejs_22
          gcc

          # Nix
          nixd
          nil
          nixpkgs-fmt
          # Scala
          coursier
          metals
          # C#
          omnisharp-roslyn
          # Python
          python3Packages.python-lsp-server
          # Bash
          bash-language-server
          # Java
          jdt-language-server
        ];

      };
    }

    (lib.mkIf (hasUserKeymaps && !config.smind.hm.zed.mutableConfig) {
      xdg.configFile."zed/keymap.json".force = true;
    })
  ]);
}

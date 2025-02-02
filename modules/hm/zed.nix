{ config, lib, pkgs, cfg-flakes, cfg-packages, cfg-meta, override_pkg, ... }:

{
  options = {
    smind.hm.zed.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.zed.enable {

    programs.zed-editor = {
      enable = true;

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
        #  base_keymap = "None";
        autosave = {
          after_delay = {
            milliseconds = 250;
          };
        };
        features = {
          copilot = false;
        };
        telemetry = {
          diagnostics = false;
          metrics = false;
        };
        vim_mode = false;
        ui_font_size = 14;
        buffer_font_size = 14;
        buffer_line_height = "standard";
        # ui_font_family = "";
        # buffer_font_fallbacks
        auto_update = false;
        buffer_font_family = "FiraMono Nerd Font";
        terminal = {
          font_family = "Hack Nerd Font Mono";
        };
        project_panel = {
          entry_spacing = "standard";
        };
        auto_signature_help = true;
        show_signature_help_after_edits = true;
        show_completions_on_input = true;
        show_completion_documentation = true;
        hover_popover_enabled = true;

        #         "use_autoclose" = true;
        # "use_auto_surround" = true;
        # "always_treat_brackets_as_autoclosed" = false;
        #  "multi_cursor_modifier" = "alt";
        "scrollbar" = {
          "show" = "auto"; # "auto" (default), "system", "always", "never"
          "cursors" = true; # Show cursor positions.
          "git_diff" = true; # Show git diff indicators.
          "search_results" = true; # Show buffer search results.
          "selected_symbol" = true; # Show selected symbol occurrences.
          "diagnostics" = true; # Show diagnostic indicators.
        };
        "gutter" = {
          "line_numbers" = true; # Show line numbers.
          "code_actions" = true; # Show code action buttons.
          "runnables" = true; # Show runnables buttons.
          "folds" = true; # Show fold buttons.
        };
        # "relative_line_numbers" = true;
      };

      userKeymaps =
        [ ];

      extraPackages = with pkgs; [
        omnisharp-roslyn
        coursier
        metals
      ];

    };

  };
}


# Opencode + Copilot + Vibe agents and the local-model (ollama) provider
# wiring. Split out of dev-llm.nix when the Claude / Codex / Pi harness and the
# shared infrastructure moved to the cq flake
# (inputs.cq.homeManagerModules.dev-llm). These agents and the local-model
# knobs stay host-side because they are tied to this machine's ollama / local
# models and host language servers.
#
# Consumes the cq module's shared surface: the read-only merged asset views
# (smind.hm.dev.llm.merged.{skills,memoryText}), the coAuthored toggle, and the
# programs.mcp registry it declares (opencode reads it via enableMcpIntegration).
{ config, lib, pkgs, inputs, outerConfig, ... }:
let
  cfg = config.smind.hm.dev.llm;

  defaultCustomModelName = "huihui_ai/qwen3.5-abliterated:35b-custom";

  tomlFormat = pkgs.formats.toml { };

  # Pre-composed context (general context + environment skill folded in) for
  # agents without skill support (Copilot, Vibe). The cq flake's
  # llm-context-with-env output IS the file (its store path).
  contextWithEnvFile =
    inputs.cq.packages.${pkgs.stdenv.hostPlatform.system}.llm-context-with-env;

  # Shared harness wiring, reconstructed from the cq module's merged views so
  # opencode gets the same skills + memory text + MCP servers as claude/codex/pi.
  sharedAgentWiring = {
    enable = true;
    enableMcpIntegration = true;
    skills = cfg.merged.skills;
    context = cfg.merged.memoryText;
  };
in
{
  options = {
    smind.hm.dev.llm.devstralContextSize = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = "Context size for devstral model in opencode (default: 128k)";
    };

    smind.hm.dev.llm.opencodeDefaultModel = lib.mkOption {
      type = lib.types.str;
      default = defaultCustomModelName;
      description = "Default model for opencode";
    };

    smind.hm.dev.llm.opencodeOllamaModelName = lib.mkOption {
      type = lib.types.str;
      default = defaultCustomModelName;
      description = "Ollama model name configured for opencode provider";
    };
  };

  config = lib.mkMerge [
    {
      smind.hm.dev.llm.devstralContextSize = lib.mkDefault (
        outerConfig.smind.llm.ollama.customContextLength or 131072
      );
      smind.hm.dev.llm.opencodeDefaultModel =
        lib.mkDefault config.smind.hm.dev.llm.opencodeOllamaModelName;
    }
    (lib.mkIf cfg.enable {
      home.sessionVariables = {
        OPENCODE_ENABLE_EXA = "1";
        # AIDER_DARK_MODE = "true";
      };

      # Copilot does not support skills — uses pre-composed context (cq llm-context-with-env)
      home.file.".copilot/copilot-instructions.md".source = contextWithEnvFile;

      home.file.".copilot-work/copilot-instructions.md".source =
        config.home.file.".copilot/copilot-instructions.md".source;

      home.file.".vibe/config.toml".source = tomlFormat.generate "vibe-config.toml" {
        system_prompt_id = "default_with_custom_instructions";
      };

      # Vibe does not support skills — uses pre-composed context (cq llm-context-with-env)
      home.file.".vibe/prompts/default_with_custom_instructions.md".source =
        contextWithEnvFile;

      home.packages = [
        pkgs.github-copilot-cli
        pkgs.mistral-vibe
      ];

      programs.opencode = sharedAgentWiring // {
        tui = {
          theme = "dark";
        };

        extraPackages = with pkgs; [
          rust-analyzer
          rustfmt
          nixd
          nixpkgs-fmt
          pyright
          bash-language-server
          shfmt
          ruff
          yaml-language-server
          metals
          jdt-language-server
          jdk21_headless
          omnisharp-roslyn
          dotnet-sdk_9
        ];

        settings = {
          autoupdate = false;
          disabled_providers = [ "openrouter" ];

          model = "ollama-cloud/minimax-m2.7";
          # web = {
          #   enable = true;
          # };
          formatter = {
            nixfmt = {
              command = [ "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt" "$FILE" ];
              extensions = [ ".nix" ];
            };
          };
          lsp = {
            metals = {
              command = [ "${pkgs.metals}/bin/metals" ];
              extensions = [
                ".scala"
                ".sc"
                ".sbt"
              ];
            };
          };
          provider = {
            ollama = {
              npm = "@ai-sdk/openai-compatible";
              options = {
                baseURL = "http://127.0.0.1:11434/v1";
              };
              models = {
                "${config.smind.hm.dev.llm.opencodeOllamaModelName}" = {
                  limit = {
                    context = config.smind.hm.dev.llm.devstralContextSize;
                    output = config.smind.hm.dev.llm.devstralContextSize;
                  };
                };
              };
            };

            openai = {
              models = {
                "gpt-5.4" = {
                  options = {
                    reasoningEffort = "xhigh";
                  };
                };
                "gpt-5.5" = {
                  options = {
                    reasoningEffort = "xhigh";
                  };
                };
              };
            };
            ollama-cloud = {
              npm = "@ai-sdk/openai-compatible";
              name = "Ollama Cloud";
              options = {
                baseURL = "https://ollama.com/v1";
              };
              models = {
                # Reasoning for Ollama Cloud models is controlled by the remote registry.
                # reasoning=true enables OpenCode thinking UI; reasoningEffort is passed
                # through the OpenAI-compatible API and may be ignored by the remote.
                "minimax-m2.7" = {
                  reasoning = true;
                  options = {
                    reasoningEffort = "high";
                  };
                };
                "kimi-k2:1t" = {
                  reasoning = false;
                };
                "kimi-k2.6" = {
                  reasoning = true;
                  options = {
                    reasoningEffort = "high";
                  };
                };
                "glm-5.1" = {
                  reasoning = true;
                  options = {
                    reasoningEffort = "high";
                  };
                };
                "nemotron-3-super" = {
                  reasoning = true;
                  options = {
                    reasoningEffort = "high";
                  };
                };
              };
            };
          };
          permission = {
            read = "allow";
            edit = "allow";
            glob = "allow";
            list = "allow";
            grep = "allow";
            websearch = "allow";
            apply_patch = "allow";
            codesearch = "allow";
            bash = "allow";
            task = "allow";
            lsp = "allow";
            question = "allow";
            webfetch = "allow";
            skill = "allow";
            todoread = "allow";
            todowrite = "allow";
            external_directory = "allow";
            doom_loop = "allow";
          };
        };
      };
    })
  ];
}

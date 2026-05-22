{ config
, lib
, pkgs
, cfg-meta
, outerConfig
, inputs
, ...
}:
let
  jsonFormat = pkgs.formats.json { };
  tomlFormat = pkgs.formats.toml { };

  codexPluginCc = pkgs.fetchFromGitHub {
    owner = "openai";
    repo = "codex-plugin-cc";
    rev = "6a5c2ba53b734f3cdd8daacbd49f68f3e6c8c167";
    hash = "sha256-4kqtfdHlcg3YXWX1og9b5JuLgnB/3Nj5dFMe4Ryt7No=";
  };
  rootlessPodmanEnabled =
    cfg-meta.isLinux
    && (outerConfig.smind.containers.docker.enable or false)
    && (outerConfig.smind.containers.docker.rootless.enable or false);
  rootlessPodmanSocketPathValue = outerConfig.smind.containers.docker.rootless.llmSocketPath or null;
  rootlessPodmanSocketUriValue = outerConfig.smind.containers.docker.rootless.llmSocketUri or null;
  rootlessPodmanSocketPath =
    if !rootlessPodmanEnabled then
      null
    else if rootlessPodmanSocketPathValue == null then
      throw "smind.containers.docker.rootless.llmSocketPath must be set when rootless Podman is enabled"
    else
      rootlessPodmanSocketPathValue;
  rootlessPodmanSocketUri =
    if !rootlessPodmanEnabled then
      null
    else if rootlessPodmanSocketUriValue == null then
      throw "smind.containers.docker.rootless.llmSocketUri must be set when rootless Podman is enabled"
    else
      rootlessPodmanSocketUriValue;

  defaultCustomModelName = "huihui_ai/qwen3.5-abliterated:35b-custom";

  # Prompt content and validated skill files live in pkg/llm-prompts/.
  # Environment guidance is delivered as a skill for agents that support skills
  # (Claude Code, Codex, Gemini CLI, OpenCode). For agents without skill support
  # (Copilot, Vibe), a pre-composed context file from the package is used instead.
  llmPrompts = pkgs.callPackage "${cfg-meta.paths.pkg}/llm-prompts/default.nix" { };

  claudeMemoryText = lib.concatStringsSep "\n\n" config.smind.hm.dev.llm.memorySections;

  # SessionStart hook: surfaces hostname and sandbox state to the agent on
  # every session boot. Claude Code's harness-injected environment block
  # lists OS/shell/cwd but not hostname, so without this the model has to
  # guess (and tends to assume the wrong host). $SMIND_SANDBOXED is set by
  # the yolo wrapper (pkg/yolo/yolo.sh) but the matching `environment`
  # skill is passive — declaring sandbox state up-front avoids relying on
  # the model to probe env vars.
  claudeSessionStartHook = pkgs.writeShellScript "claude-session-start-context" ''
    set -eu
    HOST="''${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
    if [ "''${SMIND_SANDBOXED:-0}" = "1" ]; then
      SANDBOX_LINE="Sandbox: ACTIVE (bubblewrap via the 'yolo' wrapper; SMIND_SANDBOXED=1). Writes persist only inside the project directory and /tmp/exchange. For access to \$HOME or system paths, follow the 'environment' skill's exchange-script workflow."
    else
      SANDBOX_LINE="Sandbox: NOT ACTIVE (SMIND_SANDBOXED unset). Filesystem writes are unrestricted; the exchange-script workflow is unnecessary."
    fi
    printf '%s\n' \
      'Runtime environment (injected by SessionStart hook):' \
      "- Hostname: $HOST. Use this exact value where CLAUDE.md or scripts reference the current host; do not rely on \$HOSTNAME (zsh, the user's login shell, does not export it)." \
      "- $SANDBOX_LINE"
  '';

  # Stop hook: enforce the vsm-loop "Stop conditions" contract by blocking
  # turn-end while the active ledger still has open ([ ] or [~]) entries.
  # The prompt-side discipline in pkg/llm-prompts/skills/vsm-loop is
  # advisory; this hook is what makes it load-bearing against the RLHF
  # "courtesy checkpoint" reflex. No-op outside vsm-loop projects (gated
  # on the Cycle marker the skill mandates at the top of tasks.md).
  claudeVsmLoopStopGuard = pkgs.writeShellScript "claude-vsm-loop-stop-guard" ''
    set -eu
    input=$(cat)
    # Avoid re-blocking when Claude is already responding to a prior block.
    stop_hook_active=$(printf '%s' "$input" | ${pkgs.jq}/bin/jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
    if [ "$stop_hook_active" = "true" ]; then
      exit 0
    fi
    cwd=$(printf '%s' "$input" | ${pkgs.jq}/bin/jq -r '.cwd // empty' 2>/dev/null || true)
    if [ -z "$cwd" ]; then
      cwd="$(pwd)"
    fi
    ledger=""
    for candidate in "$cwd/tasks.md" "$cwd/docs/state/tasks.md"; do
      if [ -f "$candidate" ]; then
        ledger="$candidate"
        break
      fi
    done
    if [ -z "$ledger" ]; then
      exit 0
    fi
    # vsm-loop ledgers always carry a Cycle marker; bail if it's absent so
    # we don't fire on unrelated tasks.md files.
    if ! ${pkgs.gnugrep}/bin/grep -qE '\bCycle\b' "$ledger" 2>/dev/null; then
      exit 0
    fi
    # Open = planned [ ] or in-progress [~]. Blocked [!] and done [x] are
    # valid leave-behind states (algedonic-raised or completed).
    # `grep -c` exits 1 with output "0" on no-match; capture the count and
    # only reset on actual command failure, otherwise `|| echo 0` would
    # concatenate "0\n0".
    open_count=$(${pkgs.gnugrep}/bin/grep -cE '^[[:space:]]*-[[:space:]]*\[[~ ]\]' "$ledger" 2>/dev/null) || open_count=0
    if [ "$open_count" -gt 0 ]; then
      printf '%s\n' \
        "vsm-loop ledger \"$ledger\" has $open_count open entries ([ ] or [~])." \
        "Courtesy checkpoint is not a valid stop condition — see the vsm-loop" \
        "skill § \"Stop conditions\" for the closed list of valid stop triggers." \
        "" \
        "Choose one before stopping:" \
        "  1. (default) Continue the next ledger entry. No user-facing preamble," \
        "     no menu of options, no acknowledgement that a cycle finished." \
        "  2. Raising algedonic? Flip the relevant entry to [!] in the ledger" \
        "     and emit the escalation per the skill's algedonic contract." \
        "  3. User explicitly asked to stop? Flip open entries to [!] with the" \
        "     note \"user-stopped: <reason>\" before stopping." >&2
      exit 2
    fi
    exit 0
  '';
  copilotConfig = jsonFormat.generate "copilot-config.json" {
    alt_screen = false;
    banner = "never";
    experimental = true;
    include_coauthor = config.smind.hm.dev.llm.coAuthored.enable;
    model = "gpt-5.5";
    theme = "dark";
    trusted_folders = [ ];
  };

in
{
  options = {
    smind.hm.dev.llm.enable = lib.mkEnableOption "LLM development environment variables";

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

    smind.hm.dev.llm.memorySections = lib.mkOption {
      type = lib.types.listOf lib.types.lines;
      default = [ ];
      description = "Sections used to build Claude/Codex/Gemini memory text.";
    };

    smind.hm.dev.llm.coAuthored.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include Co-Authored-By: <llm> in commit message";
    };

    smind.hm.dev.llm.fullscreenTui.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fullscreen TUI mode for agent CLIs that support it";
    };

    smind.hm.dev.llm.llmSshKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to an SSH private key to ro-bind into the yolo sandbox. Used on
        llm-worker hosts to give the unattended `llm` user access to the
        agenix-managed SSH key for git push / remote ssh from inside the
        bubblewrap sandbox. The key is bound at the same path it lives at
        on the host; agents must reference it explicitly
        (e.g. `GIT_SSH_COMMAND='ssh -i <path>'`).
      '';
    };

    smind.hm.dev.llm.yolo.extraReadOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra host paths to ro-bind into the yolo sandbox. Paths that don't
        exist on the host are silently skipped (handled by llm-sandbox.sh).
        Use this for per-host bulk storage (e.g. `/srv/nvme`) that should
        be visible read-only to sandboxed agents.
      '';
    };

    smind.hm.dev.llm.yolo.extraReadWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra host paths to rw-bind into the yolo sandbox. Same skip-on-missing
        semantics as `extraReadOnlyPaths`.
      '';
    };

    smind.hm.dev.llm.yolo.gpuByDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Default the `--gpu` flag on for `yolo` invocations on this host.
        Users can still opt out with `--no-gpu`. Has no effect on hosts
        with none of `smind.hw.{nvidia,amd.gpu,intel.gpu}.enable` set.
      '';
    };

    smind.hm.dev.llm.yolo.extraPromptFragments = lib.mkOption {
      type = lib.types.listOf lib.types.lines;
      default = [ ];
      description = ''
        Extra text fragments appended (separated by blank lines) to the
        claude `--append-system-prompt` after the YOLO authorization line.
        Use for per-host context (e.g. "this is the home NAS, /srv/nvme
        holds the photo library").
      '';
    };
  };

  config = lib.mkMerge [
    {
      smind.hm.dev.llm.devstralContextSize = lib.mkDefault (
        outerConfig.smind.llm.ollama.customContextLength or 131072
      );
      smind.hm.dev.llm.opencodeDefaultModel =
        lib.mkDefault config.smind.hm.dev.llm.opencodeOllamaModelName;
      smind.hm.dev.llm.memorySections = lib.mkBefore [ llmPrompts.baseContext ];
    }
    (lib.mkIf config.smind.hm.dev.llm.enable {
      home.sessionVariables = {
        OPENCODE_ENABLE_EXA = "1";
        # AIDER_DARK_MODE = "true";
      };

      programs.claude-code = {
        enable = true;
        # Bake DISABLE_AUTOUPDATER into the wrapper so it survives any
        # downstream wrappers (yolo, bubblewrap, fresh-env exec) and
        # prevents Claude Code from self-updating past the nix pin.
        package = pkgs.symlinkJoin {
          name = "claude-code-no-autoupdate";
          paths = [ pkgs.claude-code ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/claude --set-default DISABLE_AUTOUPDATER 1
          '';
        };
        plugins = [ "${codexPluginCc}/plugins/codex" ];
        settings = {
          alwaysThinkingEnabled = true;
          theme = "dark";
          # Workaround for Claude Code 2.1.83+ regression where sandbox
          # detection fails even when bubblewrap/socat are on PATH (the
          # error reads "sandbox required but unavailable: ${j$}").
          sandbox = {
            failIfUnavailable = false;
          };
          tui = lib.mkIf config.smind.hm.dev.llm.fullscreenTui.enable "fullscreen";
          permissions = {
            allow = [ "Edit(/tmp/**)" ];
          };
          includeCoAuthoredBy = config.smind.hm.dev.llm.coAuthored.enable;
          effortLevel = "high";
          model = "claude-opus-4-7[1m]";
          spinnerVerbs = {
            mode = "replace";
            verbs = [ "Working" ];
          };
          hooks = {
            # Inject hostname + sandbox state into every session. See
            # claudeSessionStartHook above for rationale.
            SessionStart = [
              {
                matcher = "*";
                hooks = [
                  {
                    type = "command";
                    command = "${claudeSessionStartHook}";
                  }
                ];
              }
            ];
            # Enforce vsm-loop "Stop conditions" by blocking turn-end while
            # the active ledger still has open entries. See
            # claudeVsmLoopStopGuard above for rationale.
            Stop = [
              {
                hooks = [
                  {
                    type = "command";
                    command = "${claudeVsmLoopStopGuard}";
                  }
                ];
              }
            ];
          };
          statusLine = {
            "type" = "command";
            "command" = ''
              CLAUDE_ACCOUNT="$(${pkgs.jq}/bin/jq -r '
                .oauthAccount.emailAddress //
                .oauthAccount.email //
                .oauthAccount.account.emailAddress //
                .oauthAccount.account.email //
                .oauthAccount.name //
                .oauthAccount.displayName //
                .oauthAccount.accountName //
                .account.emailAddress //
                .account.email //
                .account.name //
                empty
              ' "$HOME/.claude.json" 2>/dev/null)"
              if [ -z "$CLAUDE_ACCOUNT" ]; then
                CLAUDE_ACCOUNT="unknown-claude-account"
              fi
              printf '\033[2m\033[35m%s \033[0m\033[2m\033[37m%s \033[0m\033[2m@ %s \033[0m\033[2m\033[36min \033[1m\033[36m%s\033[0m' "$CLAUDE_ACCOUNT" "$(whoami)" "$(hostname -s)" "$(pwd | sed "s|^$HOME|~|")"
            '';
          };
        };
        skills = llmPrompts.skills;
        context = claudeMemoryText;
      };

      programs.codex = {
        enable = true;
        skills = llmPrompts.skills;
        context = claudeMemoryText;
        settings = {
          model = "gpt-5.5";
          model_reasoning_effort = "xhigh";
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
          features.multi_agent = true;
          features.fast_mode = false;
          features.steer = true;
        };
      };

      home.file.".codex/config.toml".force = true;

      programs.gemini-cli = {
        enable = true;
        # nix-instantiate --eval -E 'builtins.fromJSON (builtins.readFile ~/.gemini/settings.json)'
        settings = {
          defaultModel = "gemini-3-pro-preview";
          general = {
            previewFeatures = true;
          };
          output = {
            format = "text";
          };
          security = {
            auth = {
              selectedType = "oauth-personal";
            };
          };
          tools = {
            autoAccept = true;
            shell = {
              showColor = true;
            };
          };
          ui = {
            footer = {
              hideContextPercentage = false;
            };
            showCitations = true;
            showLineNumbers = true;
            showMemoryUsage = true;
            showModelInfoInChat = true;
          };
          context.fileName = [
            "AGENTS.md"
            "CONTEXT.md"
            "GEMINI.md"
            "CLAUDE.md"
          ];
        };
        skills = llmPrompts.skills;
        context = {
          AGENTS = claudeMemoryText;
        };
      };

      home.file.".gemini-work/settings.json".source = config.home.file.".gemini/settings.json".source;
      home.file.".gemini-work/AGENTS.md".source = config.home.file.".gemini/AGENTS.md".source;

      home.file.".claude-work/settings.json".source =
        config.home.file."${config.programs.claude-code.configDir}/settings.json".source;
      home.file.".claude-work/CLAUDE.md".source =
        config.home.file."${config.programs.claude-code.configDir}/CLAUDE.md".source;

      # Copilot does not support skills — uses pre-composed context from llm-prompts package
      home.file.".copilot/copilot-instructions.md".source = llmPrompts.contextWithEnvFile;

      home.file.".copilot-work/copilot-instructions.md".source =
        config.home.file.".copilot/copilot-instructions.md".source;

      home.file.".vibe/config.toml".source = tomlFormat.generate "vibe-config.toml" {
        system_prompt_id = "default_with_custom_instructions";
      };

      # Vibe does not support skills — uses pre-composed context from llm-prompts package
      home.file.".vibe/prompts/default_with_custom_instructions.md".source =
        llmPrompts.contextWithEnvFile;

      programs.opencode = {
        enable = true;
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
          plugin = [ "opencode-gemini-auth@latest" ];
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

            google = {
              models = {
                "gemini-3.1-pro-preview" = {
                  options = {
                    thinkingConfig = {
                      thinkingLevel = "high";
                      includeThoughts = true;
                    };
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
        skills = llmPrompts.skills;
        context = claudeMemoryText;
      };

      # Linux-only: bubblewrap sandbox and yolo wrapper script
      home.packages = [
        pkgs.gh
        pkgs.github-copilot-cli
        pkgs.mistral-vibe
        pkgs.nodejs # required by claude-code plugins (.mjs scripts)
      ]
      ++ lib.optionals cfg-meta.isDarwin [
        inputs.claude-code-sandbox.packages."${pkgs.stdenv.hostPlatform.system}".default
      ]
      ++ lib.optionals cfg-meta.isLinux [
        # aichat
        # aider-chat
        # goose-cli
        pkgs.bubblewrap
        pkgs.reattach-llm

        (pkgs.callPackage "${cfg-meta.paths.pkg}/yolo/default.nix" {
          inherit copilotConfig;
          podmanSocketPath = if rootlessPodmanEnabled then rootlessPodmanSocketPath else null;
          podmanSocketUri = if rootlessPodmanEnabled then rootlessPodmanSocketUri else null;
          hwNvidiaEnable = outerConfig.smind.hw.nvidia.enable or false;
          hwAmdGpuEnable = outerConfig.smind.hw.amd.gpu.enable or false;
          hwIntelGpuEnable = outerConfig.smind.hw.intel.gpu.enable or false;
          llmSshKeyPath = config.smind.hm.dev.llm.llmSshKeyPath;
          gpuByDefault = config.smind.hm.dev.llm.yolo.gpuByDefault;
          extraReadOnlyPaths = config.smind.hm.dev.llm.yolo.extraReadOnlyPaths;
          extraReadWritePaths = config.smind.hm.dev.llm.yolo.extraReadWritePaths;
          extraPromptFragments = config.smind.hm.dev.llm.yolo.extraPromptFragments;
          # Bind the actual ollama models dir (services.ollama.models, default
          # `${home}/models`) instead of the bare home, and only on hosts where
          # ollama is enabled — saves binding an empty path elsewhere.
          ollamaModelsDir =
            if (outerConfig.services.ollama.enable or false)
            then outerConfig.services.ollama.models
            else null;
        })
      ];
    })
  ];
}

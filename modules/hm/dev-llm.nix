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
    cfg-meta.isLinux && (outerConfig.smind.containers.docker.rootless.enable or false);
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

  baseClaudeMemorySection = ''
    ## Project Guidelines

    ### Core Principles

    - **Think first**: Read existing files before writing code.
    - **Concise output, thorough reasoning**: Be concise in what you write to the user; be thorough in what you think through.
    - **Edit over rewrite**: Prefer editing over rewriting whole files.
    - **No re-reads**: Don't re-read files you have already read.
    - **Test before done**: Test your code before declaring it done.
    - **No fluff**: No sycophantic openers or closing fluff.
    - **Persistence**: Don't bail out partway through a task. If stuck, investigate, try a different angle, or ask — half-finished work is worse than none.
    - **Fail fast**: Use assertions, throw errors early — no graceful fallbacks.
    - **Explicit over implicit**: No default parameters or optional chaining for required values.
    - **Minimal new comments**: Only write **new** comments to explain something non-obvious. Don't delete existing comments unless they're totally useless, wrong or out-of-date.
    - **No workarounds**: Deliver sound, generic, universal solutions. When you discover a bug or problem, don't hide it — attempt to fix underlying issues, ask for assistance when you can't.
    - **Ask questions**: When instructions or requirements are unclear, incomplete, or contradictory — always ask for clarifications before proceeding.
    - **Recent versions**: Always use the most recent versions of the relevant libraries and tools.

    ### References

    - **RTFM**: Read documentation, code, and samples thoroughly, download docs when necessary, use search.
    - **Prefer recent docs**: When searching, prioritize results from the current year over older sources.
    - **Use available sources**: Explore package-manager caches when you need sources or docs that aren't in the project tree — `nix store`, cargo registry, npm cache, pip wheels, maven/coursier/ivy jars, etc.

    ### Environment

    - **Sandbox detection**: Check `$SMIND_SANDBOXED` in your environment. When set to `1`, you are running inside a bubblewrap sandbox via the `yolo-*` wrapper and the sandbox-specific guidance below applies. When unset, you are running unsandboxed with the user's normal filesystem permissions — ignore the sandbox-specific workflow and write wherever the task requires.
    - **Sandbox layout** (when `SMIND_SANDBOXED=1`): The sandbox grants access to the project directory, `/nix`, and `/tmp/exchange`. Only writes to the project directory and `/tmp/exchange` persist — everything else is ephemeral and changes will be lost.
    - **Direct execution**: Always run project commands directly (compilation, tests, linting, git, formatting, etc.) — these work fine in or out of the sandbox. Only use the script workflow below for true sandbox escapes.
    - **For system interaction** (when `SMIND_SANDBOXED=1`): When you need to access `$HOME`, modify system configuration, or reach files outside the sandbox, use this workflow:
      1. Write a shell script to `/tmp/exchange/{name}.sh`.
      2. Script structure MUST be:
         ```bash
         #!/usr/bin/env bash
         set -euxo pipefail
         bat --paging=never "$0"  # Show script contents first
         read -p "Press Enter to run, Ctrl+C to abort..."
         # Your commands here, with output captured:
         command 2>&1 | tee /tmp/exchange/{name}.out
         ```
      3. Ask user to run: `bash /tmp/exchange/{name}.sh`.
      4. After user confirms execution, use Read tool to read `/tmp/exchange/{name}.out`.
      5. NEVER proceed without reading the output file — it contains the information you need.
    - **Verbose debug scripts**: Use `set -x` so the user can see commands together with output.
    - **Nix environment**: Use `flake.nix` and `direnv` for dependencies.
    - **Commands**: Use `direnv exec DIR COMMAND [...ARGS]` and `nix run`.
      - **Commands exception**: IFF your shell has a defined `DIRENV_DIR` env var, then you are already in a direnv environment, and you **DO NOT NEED TO** execute commands via `direnv exec DIR COMMAND [...ARGS]` syntax.

    ### Code Style

    - **Type safety**: Encode domain concepts as named types (interfaces/classes/records), avoid catch-all types (Object, any) and untyped containers (string-keyed maps).
    - **SOLID**: Adhere to SOLID principles.
    - **No globals**: Pass dependencies explicitly via constructors, parameters, or DI containers — never rely on singletons, module-level mutable state, or ambient globals.
    - **No magic constants**: Use named constants.
    - **No backwards compatibility**: Refactor freely.
    - **Composition over conditionals**: Prefer composition over conditional logic.
    - **DRY**: Never duplicate, always generalize.

    ### Project Structure

    - **New docs**: When creating documentation in projects without an established docs layout, prefer `./docs/drafts/{YYYYMMDD-HHMM}-{name}.md`.
    - **Debug scripts**: When creating throwaway debug scripts, prefer `./debug/{YYYYMMDD-HHMMSS}-{name}.{ext}` (use the appropriate extension for the project language).
    - **Services**: Use interface + implementation pattern when possible.
    - **Gitignore**: Always create and maintain reasonable `.gitignore` files.

    ### Tools

    - **Debuggers**: Use the debugger appropriate for the language at hand.
    - **Parallelism**: Use `nproc` to determine available parallel processes.
    - **Unattended mode**: Always run tools in batch mode, especially tools like SBT which expect user input by default.
  '';

  claudeMemoryText = lib.concatStringsSep "\n\n" config.smind.hm.dev.llm.memorySections;
  copilotConfig = jsonFormat.generate "copilot-config.json" {
    alt_screen = false;
    banner = "never";
    experimental = true;
    include_coauthor = config.smind.hm.dev.llm.coAuthored.enable;
    model = "gpt-5.4";
    theme = "dark";
    trusted_folders = [ ];
  };

  containerSocketForwardingSnippet = ''
    SOCKET_ARGS=()
    ${lib.optionalString rootlessPodmanEnabled ''
      ROOTLESS_PODMAN_SOCKET_PATH=${lib.escapeShellArg rootlessPodmanSocketPath}
      ROOTLESS_PODMAN_SOCKET_URI=${lib.escapeShellArg rootlessPodmanSocketUri}

      if [[ -S "$ROOTLESS_PODMAN_SOCKET_PATH" ]]; then
        SOCKET_ARGS+=(--rw "$ROOTLESS_PODMAN_SOCKET_PATH")
        SOCKET_ARGS+=(--env "DOCKER_HOST=$ROOTLESS_PODMAN_SOCKET_URI")
        SOCKET_ARGS+=(--env "CONTAINER_HOST=$ROOTLESS_PODMAN_SOCKET_URI")
      else
        echo "warning: podsvc-llm Podman socket not available, skipping bind: $ROOTLESS_PODMAN_SOCKET_PATH" >&2
      fi
    ''}
  '';
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
  };

  config = lib.mkMerge [
    {
      smind.hm.dev.llm.devstralContextSize = lib.mkDefault (
        outerConfig.smind.llm.ollama.customContextLength or 131072
      );
      smind.hm.dev.llm.opencodeDefaultModel =
        lib.mkDefault config.smind.hm.dev.llm.opencodeOllamaModelName;
      smind.hm.dev.llm.memorySections = lib.mkBefore [ baseClaudeMemorySection ];
    }
    (lib.mkIf config.smind.hm.dev.llm.enable {
      home.sessionVariables = {
        OLLAMA_API_BASE = "http://127.0.0.1:11434";
        # AIDER_DARK_MODE = "true";
      };

      programs.claude-code = {
        enable = true;
        plugins = [ "${codexPluginCc}/plugins/codex" ];
        settings = {
          alwaysThinkingEnabled = true;
          theme = "dark";
          permissions = {
            allow = [ "Edit(/tmp/**)" ];
          };
          includeCoAuthoredBy = config.smind.hm.dev.llm.coAuthored.enable;
          effortLevel = "high";
          model = "claude-opus-4-6[1m]";
          spinnerVerbs = {
            mode = "replace";
            verbs = [ "Working" ];
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
        memory.text = claudeMemoryText;
      };

      programs.codex = {
        enable = true;
        custom-instructions = claudeMemoryText;
        settings = {
          model = "gpt-5.4";
          model_reasoning_effort = "xhigh";
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
          features.multi_agent = true;
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
        context = {
          AGENTS = claudeMemoryText;
        };
      };

      home.file.".gemini-work/settings.json".source = config.home.file.".gemini/settings.json".source;
      home.file.".gemini-work/AGENTS.md".source = config.home.file.".gemini/AGENTS.md".source;

      home.file.".claude-work/settings.json".source = config.home.file.".claude/settings.json".source;
      home.file.".claude-work/CLAUDE.md".source = config.home.file.".claude/CLAUDE.md".source;

      home.file.".copilot/copilot-instructions.md".text = claudeMemoryText;

      home.file.".copilot-work/copilot-instructions.md".source =
        config.home.file.".copilot/copilot-instructions.md".source;

      programs.zsh.shellAliases = lib.mkIf cfg-meta.isLinux {
        copilot = "yolo-copilot";
        copilot-work = "yolo-copilot-work";
      };

      programs.nushell.shellAliases = lib.mkIf cfg-meta.isLinux {
        copilot = "yolo-copilot";
        copilot-work = "yolo-copilot-work";
      };

      home.file.".vibe/config.toml".source = tomlFormat.generate "vibe-config.toml" {
        system_prompt_id = "default_with_custom_instructions";
      };

      home.file.".vibe/prompts/default_with_custom_instructions.md".text = claudeMemoryText;

      programs.opencode = {
        enable = true;
        settings = {
          theme = "dark";
          autoupdate = "notify";
          model = config.smind.hm.dev.llm.opencodeDefaultModel;
          plugin = [ "opencode-gemini-auth@latest" ];
          provider = {
            google = {
              models = {
                "gemini-3-pro-preview" = {
                  options = {
                    thinkingConfig = {
                      thinkingLevel = "high";
                      includeThoughts = true;
                    };
                  };
                };
              };
            };
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
          };
          permission = {
            read = "allow";
            edit = "allow";
            glob = "allow";
            list = "allow";
            grep = "allow";
            websearch = "allow";
            codesearch = "allow";
            bash = "allow";
            task = "allow";
            lsp = "allow";
            webfetch = "allow";
            skill = "allow";
            todoread = "allow";
            todowrite = "allow";
            external_directory = "allow";
            doom_loop = "allow";
          };
        };
        rules = claudeMemoryText;
      };

      # Linux-only: bubblewrap sandbox and yolo-* wrapper scripts
      home.packages = [
        pkgs.gh
        pkgs.github-copilot-cli
        pkgs.mistral-vibe
        pkgs.nodejs # required by claude-code plugins (.mjs scripts)
      ]
      ++ lib.optionals cfg-meta.isDarwin [
        inputs.claude-code-sandbox.packages."${pkgs.stdenv.hostPlatform.system}".default
      ]
      ++ lib.optionals cfg-meta.isLinux (
        let
          firejail-wrap = pkgs.firejail-wrap;
          nix-ld = pkgs.nix-ld;
        in
        [
          # aichat
          # aider-chat
          # goose-cli
          pkgs.bubblewrap
          pkgs.reattach-llm

          (pkgs.writeShellScriptBin "yolo-claude" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.claude" \
              --rw "''${HOME}/.claude.json" \
              --rw "''${HOME}/.config/claude" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- claude --permission-mode bypassPermissions "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-claude-work" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            mkdir -p "$HOME/.claude-work"
            mkdir -p "$HOME/.claude-work-home"
            mkdir -p "$HOME/.config/claude-work"
            touch "$HOME/.claude-work-home/.claude.json"
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --bind "''${HOME}/.claude-work,''${HOME}/.claude" \
              --bind "''${HOME}/.claude-work-home/.claude.json,''${HOME}/.claude.json" \
              --bind "''${HOME}/.config/claude-work,''${HOME}/.config/claude" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- claude --permission-mode bypassPermissions "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-copilot" ''
            ENV_ARGS=()
            CMD_ARGS=()
            COPILOT_CONFIG_DIR="$HOME/.copilot"
            RAW_COPILOT="${pkgs.github-copilot-cli}/bin/copilot"
            COPILOT_DEFAULT_CONFIG="${copilotConfig}"

            ensure_copilot_config() {
              local config_dir="$1"
              local trusted_dir="$2"
              local config_file="$config_dir/config.json"
              local tmp_config

              mkdir -p "$config_dir"
              tmp_config="$(mktemp)"

              if [[ -f "$config_file" ]]; then
                ${pkgs.jq}/bin/jq \
                  --slurpfile defaults "$COPILOT_DEFAULT_CONFIG" \
                  --arg trusted_dir "$trusted_dir" \
                  '
                    ($defaults[0] + .)
                    | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
                  ' \
                  "$config_file" > "$tmp_config"
              else
                ${pkgs.jq}/bin/jq \
                  -n \
                  --slurpfile defaults "$COPILOT_DEFAULT_CONFIG" \
                  --arg trusted_dir "$trusted_dir" \
                  '
                    $defaults[0]
                    | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
                  ' > "$tmp_config"
              fi

              mv "$tmp_config" "$config_file"
            }

            copilot_args=(
              --config-dir "$COPILOT_CONFIG_DIR"
            )

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done

            ensure_copilot_config "$COPILOT_CONFIG_DIR" "$PWD"

            case "''${CMD_ARGS[0]-}" in
              help|init|login|plugin|update|version)
                ;;
              *)
                copilot_args+=(
                  --model gpt-5.4
                  --reasoning-effort xhigh
                  --autopilot
                  --yolo
                )
                ;;
            esac

            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
                --rw "''${PWD}" \
                --rw "''${HOME}/.copilot" \
                --rw "''${HOME}/.cache" \
                --rw "''${HOME}/.ivy2" \
                "''${SOCKET_ARGS[@]}" \
                --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/gh" \
              --ro "''${HOME}/.config/direnv" \
                --ro "''${HOME}/.local/share/direnv" \
                --ro "''${HOME}/.direnvrc" \
                --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
                --env SMIND_SANDBOXED=1 \
                "''${ENV_ARGS[@]}" \
                -- "$RAW_COPILOT" "''${copilot_args[@]}" "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-copilot-work" ''
            ENV_ARGS=()
            CMD_ARGS=()
            COPILOT_CONFIG_DIR="$HOME/.copilot-work"
            RAW_COPILOT="${pkgs.github-copilot-cli}/bin/copilot"
            COPILOT_DEFAULT_CONFIG="${copilotConfig}"

            ensure_copilot_config() {
              local config_dir="$1"
              local trusted_dir="$2"
              local config_file="$config_dir/config.json"
              local tmp_config

              mkdir -p "$config_dir"
              tmp_config="$(mktemp)"

              if [[ -f "$config_file" ]]; then
                ${pkgs.jq}/bin/jq \
                  --slurpfile defaults "$COPILOT_DEFAULT_CONFIG" \
                  --arg trusted_dir "$trusted_dir" \
                  '
                    ($defaults[0] + .)
                    | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
                  ' \
                  "$config_file" > "$tmp_config"
              else
                ${pkgs.jq}/bin/jq \
                  -n \
                  --slurpfile defaults "$COPILOT_DEFAULT_CONFIG" \
                  --arg trusted_dir "$trusted_dir" \
                  '
                    $defaults[0]
                    | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
                  ' > "$tmp_config"
              fi

              mv "$tmp_config" "$config_file"
            }

            copilot_args=(
              --config-dir "$COPILOT_CONFIG_DIR"
            )

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done

            ensure_copilot_config "$COPILOT_CONFIG_DIR" "$PWD"

            case "''${CMD_ARGS[0]-}" in
              help|init|login|plugin|update|version)
                ;;
              *)
                copilot_args+=(
                  --model gpt-5.4
                  --reasoning-effort xhigh
                  --autopilot
                  --yolo
                )
                ;;
            esac

            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
                --rw "''${PWD}" \
                --rw "''${HOME}/.copilot-work" \
                --rw "''${HOME}/.cache" \
                --rw "''${HOME}/.ivy2" \
                "''${SOCKET_ARGS[@]}" \
                --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/gh" \
              --ro "''${HOME}/.config/direnv" \
                --ro "''${HOME}/.local/share/direnv" \
                --ro "''${HOME}/.direnvrc" \
                --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
                --env SMIND_SANDBOXED=1 \
                "''${ENV_ARGS[@]}" \
                -- "$RAW_COPILOT" "''${copilot_args[@]}" "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-codex" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.codex" \
              --rw "''${HOME}/.config/codex" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- codex --dangerously-bypass-approvals-and-sandbox --search "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-gemini" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.gemini" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- gemini --yolo "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-gemini-work" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --bind "''${HOME}/.gemini-work,''${HOME}/.gemini" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- gemini --yolo "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-mistral-vibe" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            mkdir -p "$HOME/.vibe"
            mkdir -p "$HOME/.local/share/vibe"
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.vibe" \
              --rw "''${HOME}/.local/share/vibe" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
            -- vibe --agent auto-approve "''${CMD_ARGS[@]}"
          '')

          (pkgs.writeShellScriptBin "yolo-opencode" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            ${containerSocketForwardingSnippet}
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.config/opencode" \
              --rw "''${HOME}/.local/share/opencode" \
              --rw "''${HOME}/.cache" \
              --rw "''${HOME}/.ivy2" \
              "''${SOCKET_ARGS[@]}" \
              --ro "''${HOME}/.config/git" \
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              --ro-bind "${nix-ld}/bin/nix-ld,/lib64/ld-linux-x86-64.so.2" \
              --env SMIND_SANDBOXED=1 \
              "''${ENV_ARGS[@]}" \
              -- opencode "''${CMD_ARGS[@]}"
          '')
        ]
      );
    })
  ];
}

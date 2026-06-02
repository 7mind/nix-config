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

  codegraphPkg = inputs.codegraph.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # nixpkgs' claude-code runs its inner binary via `exec ld.so --library-path … inner`,
  # so Node's process.execPath is the dynamic loader. Claude exports that as
  # CLAUDE_CODE_EXECPATH, and the grep/find shims it writes into its shell snapshot
  # then invoke `ld.so -G …` / `ld.so -S …` → "error while loading shared libraries: -G".
  # Make the inner binary self-contained (real glibc interp + rpath, taken from the
  # wrapper's own --library-path so the glibc always matches) and exec it DIRECTLY, so
  # execPath is the real binary and the bundled ugrep/bfs multiplex (keyed on argv0)
  # works. Verified: `exec -a ugrep <inner> -G …` greps correctly once run directly.
  claudeExecpathFixed = pkgs.claude-code.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.patchelf ];
    postFixup = (old.postFixup or "") + ''
      inner="$out/libexec/claude-code/claude"
      if [ ! -e "$inner" ]; then
        echo "claudeExecpathFixed: inner binary missing at $inner" >&2; exit 1
      fi
      wrapper=""
      for w in "$out"/bin/*; do
        if [ -f "$w" ] && grep -qE 'ld-linux.*libexec/claude-code/claude' "$w"; then
          wrapper="$w"; break
        fi
      done
      if [ -z "$wrapper" ]; then
        echo "claudeExecpathFixed: no loader-indirection wrapper found" >&2; exit 1
      fi
      glibclib="$(grep -oE '/nix/store/[^ "]*-glibc-[^ "]*/lib' "$wrapper" | head -1)"
      if [ -z "$glibclib" ]; then
        echo "claudeExecpathFixed: could not determine glibc lib path" >&2; exit 1
      fi
      patchelf --set-interpreter "$glibclib/ld-linux-x86-64.so.2" --set-rpath "$glibclib" "$inner"
      for w in "$out"/bin/*; do
        [ -f "$w" ] && grep -qE 'ld-linux.*libexec/claude-code/claude' "$w" || continue
        grep -v -E '^exec .*ld-linux.*libexec/claude-code/claude' "$w" > "$w.tmp"
        printf 'exec -a "$0" %s "$@"\n' "$inner" >> "$w.tmp"
        chmod --reference="$w" "$w.tmp" 2>/dev/null || chmod +x "$w.tmp"
        mv "$w.tmp" "$w"
        if grep -qE 'ld-linux.*libexec/claude-code/claude' "$w"; then
          echo "claudeExecpathFixed: failed to rewrite $w" >&2; exit 1
        fi
      done
    '';
  });

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
  # (Claude Code, Codex, OpenCode, Pi). For agents without skill support
  # (Copilot, Vibe), a pre-composed context file from the package is used instead.
  llmPrompts = pkgs.callPackage "${cfg-meta.paths.pkg}/llm-prompts/default.nix" { };

  # The ledger flake (markdown-ledger MCP project, github:pshirshov/cq).
  ledgerPkgs = inputs.ledger.packages.${pkgs.stdenv.hostPlatform.system};
  ledgerPkg = ledgerPkgs.ledger-mcp;
  ledgerAssets = inputs.ledger.llmAssets;
  # The ledger-* CLI tools (ledger-mcp/ledger-tui/ledger-web) put on PATH so
  # the agents (and the user) can drive the ledger directly, not only via MCP.
  ledgerTools = [
    ledgerPkgs.ledger-mcp
    ledgerPkgs.ledger-tui
    ledgerPkgs.ledger-web
  ];

  # The in-repo llm-prompts package now emits the canonical llmAssets bundle
  # directly ({ skills; commands; agents; context = [ baseContext ]; }), so
  # it is a first-class bundle contributor symmetric with ledger.llmAssets —
  # no manual reassembly here.

  # Aggregate every contributed asset bundle into one merged view. Mirrors
  # the memorySections list-contribution idiom: any module/flake appends a
  # bundle to smind.hm.dev.llm.assetBundles and the materializer below fans
  # it into every agent. Later bundles win on key collisions (`//`).
  assetBundles = config.smind.hm.dev.llm.assetBundles;
  mergeAttrField = field: lib.foldl' (acc: b: acc // b.${field}) { } assetBundles;
  mergedSkills = mergeAttrField "skills";
  mergedCommands = mergeAttrField "commands";
  mergedAgents = mergeAttrField "agents";
  mergedContext = lib.concatMap (b: b.context) assetBundles;

  # Pi: vendored 0.78.0 formula (nixpkgs lags at 0.75.x, whose Codex/ChatGPT
  # subscription token exchange is broken). Bump procedure: edit version +
  # rerun the two fake-hash builds in pkg/pi-coding-agent/package.nix.
  piBase = pkgs.callPackage "${cfg-meta.paths.pkg}/pi-coding-agent/package.nix" { };

  # Secret-keyed env injected into Pi at launch from agenix secret files (read
  # only if present, so hosts without them degrade gracefully). Keeps tokens
  # out of the Nix store and the at-rest environment — they live only in pi's
  # process env at runtime. var -> agenix secret name under /run/agenix.
  piSecretEnv = {
    OPENROUTER_API_KEY = "openrouter";
    AI_GATEWAY_API_KEY = "vercel"; # Vercel AI Gateway
    EXA_API_KEY = "exa";
    BRAVE_SEARCH_API_KEY = "brave";
    FIRECRAWL_API_KEY = "firecrawl";
  };
  piSecretsPrelude = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      var: secret: ''[ -r /run/agenix/${secret} ] && export ${var}="$(cat /run/agenix/${secret})"''
    ) piSecretEnv
  );
  piWrapped = pkgs.symlinkJoin {
    name = "pi-coding-agent-wrapped";
    paths = [ piBase ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/pi \
        --run ${lib.escapeShellArg piSecretsPrelude} \
        --set-default SEARXNG_URL https://searx.web.7mind.io
    '';
  };

  # Default rpiv-web-tools config: route web search through our own SearXNG.
  # Seeded as a writable copy (not a store symlink) so the tool's own
  # `/web-tools` command and runtime persistence keep working. API keys are
  # NOT stored here — they come from the env injected by piWrapped.
  rpivWebToolsConfig = jsonFormat.generate "rpiv-web-tools-config.json" {
    provider = "searxng";
    baseUrls.searxng = "https://searx.web.7mind.io";
  };

  # Pi has no native MCP; pi-mcp-adapter (in settings.packages via
  # enableMcpIntegration) auto-reads ~/.config/mcp/mcp.json — but servers there
  # are lazy (connect on first tool call). This Pi-only override (higher
  # precedence than the shared file) re-declares the same servers with
  # lifecycle="keep-alive" so Pi connects them at startup and auto-reconnects.
  # Kept out of the shared programs.mcp registry so the `lifecycle` key doesn't
  # leak into claude/codex's transformed MCP configs.
  piMcpJson = jsonFormat.generate "pi-mcp.json" {
    mcpServers = lib.mapAttrs (_name: server: server // { lifecycle = "keep-alive"; }) (
      config.programs.mcp.servers
    );
  };

  claudeMemoryText = lib.concatStringsSep "\n\n" config.smind.hm.dev.llm.memorySections;

  # Wiring common to every skill-aware harness: enable it, feed the shared
  # programs.mcp registry, install the merged skill set, and the shared
  # memory text. Spread with `//` into each programs.<harness> block (no key
  # overlap with the harness-specific options).
  sharedAgentWiring = {
    enable = true;
    enableMcpIntegration = true;
    skills = mergedSkills;
    context = claudeMemoryText;
  };

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
      description = "Sections used to build Claude/Codex memory text.";
    };

    smind.hm.dev.llm.assetBundles = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            skills = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = { };
              description = "name -> SKILL.md content ('---\\nmeta---\\n\\ncontent').";
            };
            commands = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = { };
              description = "key '<ns>/<name>' -> markdown body (slash command /<ns>:<name>).";
            };
            agents = lib.mkOption {
              type = lib.types.attrsOf lib.types.lines;
              default = { };
              description = "name -> subagent definition (with name/description/tools frontmatter).";
            };
            context = lib.mkOption {
              type = lib.types.listOf lib.types.lines;
              default = [ ];
              description = "CLAUDE.md/AGENTS.md memory fragments.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Contributed LLM asset bundles (cross-repo llmAssets shape). Any
        module or flake appends a bundle here; a single materializer fans
        every asset type (skills, commands, agents, context) into every
        agent's filesystem layout globally. Mirrors the memorySections
        list-contribution idiom.
      '';
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
      # Base context (and any other bundle context fragments) flow in via the
      # asset bundles; mkBefore keeps them ahead of host/user-specific
      # sections appended elsewhere with mkAfter.
      smind.hm.dev.llm.memorySections = lib.mkBefore mergedContext;
      # In-repo prompts first (base), ledger after (may override on key
      # collisions). External modules append further bundles elsewhere.
      smind.hm.dev.llm.assetBundles = lib.mkBefore [ llmPrompts.llmAssets ledgerAssets ];
    }
    (lib.mkIf config.smind.hm.dev.llm.enable {
      home.sessionVariables = {
        OPENCODE_ENABLE_EXA = "1";
        # AIDER_DARK_MODE = "true";
      };

      # CodeGraph MCP server — declared once here and pulled into each
      # agent CLI via its enableMcpIntegration option below. The server
      # is started on-demand per project by the agent; building the
      # per-project index is a manual `codegraph init -i` step.
      programs.mcp = {
        enable = true;
        servers.codegraph = {
          command = "${codegraphPkg}/bin/codegraph";
          args = [ "serve" "--mcp" ];
        };
        # markdown-ledger MCP server. stdio transport; --cwd defaults to the
        # agent's process CWD, so one global server serves a per-project
        # ledger. Pass "--http" "PORT" instead for a shared HTTP instance.
        servers.ledger = {
          command = "${ledgerPkg}/bin/ledger-mcp";
          args = [ ];
        };
      };

      programs.claude-code = sharedAgentWiring // {
        # Bake DISABLE_AUTOUPDATER into the wrapper so it survives any
        # downstream wrappers (yolo, bubblewrap, fresh-env exec) and
        # prevents Claude Code from self-updating past the nix pin.
        package = pkgs.symlinkJoin {
          name = "claude-code-no-autoupdate";
          paths = [ claudeExecpathFixed ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/claude --set-default DISABLE_AUTOUPDATER 1
          '';
        };
        plugins = [ "${codexPluginCc}/plugins/codex" ];
        # Bundle-contributed commands/agents via the native options: keys
        # like "plan/advance" land at ~/.claude/commands/plan/advance.md
        # (slash command /plan:advance); agents at ~/.claude/agents/<name>.md.
        commands = mergedCommands;
        agents = mergedAgents;
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
          model = "claude-opus-4-8[1m]";
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
      };

      programs.codex = sharedAgentWiring // {
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

      programs.pi = sharedAgentWiring // {
        # Vendored Pi 0.78.0 wrapped to inject provider/search API keys from
        # agenix secrets at launch (see piWrapped/piSecretEnv). Default model is
        # GPT-5.5 at max reasoning via the Codex/ChatGPT subscription (OAuth via
        # `pi` /login; no API key needed for the default).
        package = piWrapped;
        settings = {
          theme = "dark";
          # ChatGPT Plus/Pro (Codex) subscription via OAuth (`pi` /login). The
          # subscription provider id is "openai-codex" and it serves the
          # gpt-*-codex models (NOT the API "gpt-5.5", which needs an OpenAI API
          # key). `xhigh` reasoning is only supported on codex-max models, so we
          # default to the codex-max flagship for "max reasoning". The api-key
          # `openai`/openrouter/vercel providers stay available via injected env.
          defaultProvider = "openai-codex";
          defaultModel = "gpt-5.1-codex-max";
          defaultThinkingLevel = "xhigh";
          # Pi packages (installed from npm on first run):
          # - rpiv-web-tools: web search/fetch (keys via piWrapped env, SearXNG
          #   default; config seeded at ~/.config/rpiv-web-tools/config.json).
          # - pi-anthropic-auth: improves Claude Pro/Max OAuth compatibility;
          #   activates only on Anthropic OAuth, passes everything else through
          #   (use `/login anthropic`). pi-mcp-adapter is added separately by
          #   enableMcpIntegration.
          packages = [
            "npm:@juicesharp/rpiv-web-tools"
            "npm:@gotgenes/pi-anthropic-auth"
          ];
        };
      };

      # Pi-specific MCP override: codegraph + ledger pinned keep-alive so Pi's
      # pi-mcp-adapter connects them at startup (see piMcpJson).
      home.file.".pi/agent/mcp.json".source = piMcpJson;

      # Seed a writable rpiv-web-tools config (SearXNG default) once, leaving it
      # user/tool-writable thereafter. Replaces an HM store symlink if present.
      home.activation.rpivWebToolsConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        _rpiv_cfg="${config.home.homeDirectory}/.config/rpiv-web-tools/config.json"
        if [ ! -e "$_rpiv_cfg" ] || [ -L "$_rpiv_cfg" ]; then
          run mkdir -p "$(dirname "$_rpiv_cfg")"
          run rm -f "$_rpiv_cfg"
          run install -m600 ${rpivWebToolsConfig} "$_rpiv_cfg"
        fi
      '';

      # Linux-only: bubblewrap sandbox and yolo wrapper script
      home.packages = [
        pkgs.gh
        pkgs.github-copilot-cli
        pkgs.mistral-vibe
        pkgs.nodejs # required by claude-code plugins (.mjs scripts)
        codegraphPkg # for `codegraph init -i` per-project bootstrap
      ]
      ++ ledgerTools
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
          codegraph = codegraphPkg;
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
    (lib.mkIf config.smind.hm.dev.llm.enable {
      # Codex exposes no native commands/agents option (unlike claude-code),
      # so deliver merged commands as ~/.codex/prompts/<name>.md slash-prompts.
      # Kept in a separate mkMerge element because the block above sets
      # `home.file."<path>"` via attrpaths, which cannot coexist with a
      # dynamic `home.file = <attrs>` in the same attribute set.
      # baseNameOf strips the "<ns>/" prefix ("plan/advance" ->
      # prompts/advance.md); cross-namespace basename collisions would clash.
      # Codex agents have no canonical markdown home and are intentionally
      # not materialized for Codex (Claude receives them via its agents option).
      home.file = lib.mapAttrs' (
        key: body: lib.nameValuePair ".codex/prompts/${baseNameOf key}.md" { text = body; }
      ) mergedCommands;
    })
  ];
}

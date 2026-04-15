### Environment

- **Sandbox detection**: Check `$SMIND_SANDBOXED` in your environment. When set to `1`, you are running inside a bubblewrap sandbox via the `yolo` wrapper and the sandbox-specific guidance below applies. When unset, you are running unsandboxed with the user's normal filesystem permissions — ignore the sandbox-specific workflow and write wherever the task requires.
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

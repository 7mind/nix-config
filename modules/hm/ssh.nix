{ config, cfg-meta, lib, ... }:

{
  options = {
    smind.hm.ssh.enable = lib.mkEnableOption "SSH client configuration";
  };

  config = lib.mkIf config.smind.hm.ssh.enable {
    # there is programs.ssh.startAgent = true, but it conflicts with gnome keychain and ssh forwarding
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks."*" = {
        addKeysToAgent = lib.mkIf cfg-meta.isLinux "yes";
        extraOptions = {
          "IgnoreUnknown" = "UseKeychain";
          "UseKeychain" = "yes";
        };
      };
    };

    programs.zsh.envExtra = lib.mkIf (cfg-meta.isLinux && config.services.ssh-agent.enable) ''
      if [ -z "$SSH_AUTH_SOCK" ] || ! [ -S "$SSH_AUTH_SOCK" ]; then
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent"
      fi
    '';

    # Validate SSH_AUTH_SOCK on each prompt; recover if the socket went stale
    # (e.g. SSH reconnect while inside tmux leaves existing shells with a dead path).
    programs.zsh.initExtra = lib.mkIf cfg-meta.isLinux ''
      _smind_fix_ssh_sock() {
        [[ -S "''${SSH_AUTH_SOCK:-}" ]] && return

        # Try forwarded agent sockets (OpenSSH >=10 stores them in ~/.ssh/agent/)
        if [[ -d "$HOME/.ssh/agent" ]]; then
          local sock
          for sock in "$HOME"/.ssh/agent/*(N=Om); do
            [[ -S "$sock" ]] && { export SSH_AUTH_SOCK="$sock"; return; }
          done
        fi

        # Try tmux session environment (update-environment refreshes it on attach)
        if [[ -n "''${TMUX:-}" ]]; then
          local val
          val=$(tmux show-environment SSH_AUTH_SOCK 2>/dev/null) || true
          if [[ "$val" == SSH_AUTH_SOCK=* ]]; then
            local candidate="''${val#SSH_AUTH_SOCK=}"
            [[ -S "$candidate" ]] && { export SSH_AUTH_SOCK="$candidate"; return; }
          fi
        fi

        # Fall back to local agents (GCR, then HM standalone ssh-agent)
        local runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        local candidate
        for candidate in "$runtime_dir/gcr/ssh" "$runtime_dir/ssh-agent"; do
          [[ -S "$candidate" ]] && { export SSH_AUTH_SOCK="$candidate"; return; }
        done
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _smind_fix_ssh_sock
    '';
  };
}

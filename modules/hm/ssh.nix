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

    # `resock`: manually re-point SSH_AUTH_SOCK at a live agent.
    # Probes forwarded sockets first, deletes dead ones, falls back to the
    # local agent. Intended for use after SSH reconnects into a persisted
    # tmux/screen session where existing shells hold a stale SSH_AUTH_SOCK.
    programs.zsh.initContent = lib.mkIf cfg-meta.isLinux ''
      resock() {
        emulate -L zsh
        setopt local_options null_glob

        # Forwarded-socket locations: OpenSSH default is /tmp/ssh-*/agent.*;
        # some setups expose them under ~/.ssh/agent/.
        local -a forwarded=( /tmp/ssh-*/agent.*(=om) $HOME/.ssh/agent/*(=om) )
        local runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        local -a locals=( "$runtime_dir/gcr/ssh" "$runtime_dir/ssh-agent" )
        local sock rc

        _resock_try() {
          # returns 0 if agent responded (has keys or empty), 2 if unreachable
          SSH_AUTH_SOCK="$1" command timeout 1 ssh-add -l >/dev/null 2>&1
          rc=$?
          (( rc != 2 ))
        }

        if (( ''${#forwarded} == 0 )); then
          print "resock: no forwarded sockets found"
        else
          print "resock: probing ''${#forwarded} forwarded socket(s)"
          for sock in $forwarded; do
            printf '  %s ... ' "$sock"
            if _resock_try "$sock"; then
              print "alive"
              export SSH_AUTH_SOCK="$sock"
              print "resock: SSH_AUTH_SOCK -> $sock"
              unfunction _resock_try
              return 0
            fi
            print "dead (removing)"
            rm -f -- "$sock"
          done
        fi

        print "resock: falling back to local agent"
        for sock in $locals; do
          printf '  %s ... ' "$sock"
          if [[ ! -S "$sock" ]]; then
            print "missing"
            continue
          fi
          if _resock_try "$sock"; then
            print "alive"
            export SSH_AUTH_SOCK="$sock"
            print "resock: SSH_AUTH_SOCK -> $sock"
            unfunction _resock_try
            return 0
          fi
          print "unresponsive"
        done

        unfunction _resock_try
        print -u2 "resock: no working agent found"
        return 1
      }
    '';
  };
}

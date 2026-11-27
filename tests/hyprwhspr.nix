{ pkgs, package }:

let
  probe = pkgs.writeText "hyprwhspr-qwen-probe.py" ''
    import os
    import subprocess
    import shutil
    import sys
    from pathlib import Path
    import dbus, sounddevice, soundfile, soxr, evdev, pyudev, pulsectl
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    assert shutil.which('xkbcli'), 'xkbcli is required for GNOME keyboard-layout detection'
    sys.path.insert(0, '${package}/lib/hyprwhspr/lib')
    from src import qwen3_asr_runtime as runtime
    from src.installation import is_supported_backend
    assert is_supported_backend('qwen3-asr')
    assert runtime.runtime_release() == 'b10516'
    assert runtime.packaged_devices() == ('cpu', 'vulkan')
    for device in runtime.packaged_devices():
        env = {**os.environ, 'LD_LIBRARY_PATH': str(runtime.library_dir(device))}
        result = subprocess.run([runtime.server_path(device), '--version'], env=env,
                                capture_output=True, text=True, check=True)
        assert '10516' in result.stdout + result.stderr, result
    assert not os.path.exists(os.path.join(os.environ['XDG_DATA_HOME'], 'hyprwhspr', 'venv'))
    Path(os.environ['XDG_RUNTIME_DIR'], 'probe-ok').touch()
  '';
  editor = pkgs.writeShellScript "hyprwhspr-qwen-probe" ''
    exec ${package.python}/bin/python ${probe}
  '';
in
pkgs.runCommand "hyprwhspr-qwen-smoke"
  {
    nativeBuildInputs = [ package ];
  }
  ''
    export XDG_CONFIG_HOME="$TMPDIR/config"
    export XDG_DATA_HOME="$TMPDIR/data"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/hyprwhspr"
    cat > "$XDG_CONFIG_HOME/hyprwhspr/config.json" <<'JSON'
    {"transcription_backend":"qwen3-asr","qwen3_asr_model":"0.6b-q8_0","qwen3_asr_device":"cpu","language":"en","external_bindings":true}
    JSON
    hyprwhspr --help
    hyprwhspr --version | grep -F '${package.version}'
    hyprwhspr install status | grep -F Qwen3-ASR
    hyprwhspr model list | grep -F '0.6b-q8_0'
    hyprwhspr config show | grep -F qwen3-asr
    if hyprwhspr model download unsupported > "$TMPDIR/unsupported-model" 2>&1; then
      exit 1
    fi
    grep -F 'Unsupported Qwen3-ASR model: unsupported' "$TMPDIR/unsupported-model"
    EDITOR=${editor} hyprwhspr config edit
    test -f "$XDG_RUNTIME_DIR/probe-ok"
    touch "$out"
  ''

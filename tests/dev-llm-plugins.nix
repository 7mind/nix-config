{ flake, pkgs }:
let
  lib = pkgs.lib;
  configuration = (flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      flake.inputs.ponygirls.homeManagerModules.dev-llm
      ../modules/hm/dev-llm-plugins.nix
      {
        home = {
          username = "engineer";
          homeDirectory = "/build/home";
          stateVersion = "26.05";
        };
        smind.hm.dev.llm = {
          enable = true;
          iHaveAdhdPlugin.enable = true;
          cavemanPlugin.enable = true;
        };
      }
    ];
  }).config;
  plugin = builtins.head configuration.programs.codex.plugins;
  trust = configuration.programs.codex.settings.hooks.state;
  skills = configuration.programs.codex.skills;
in
# BG @specified: all harnesses retain the approved skill and its advertised aliases.
assert lib.assertMsg (plugin.version == "0.4.1") "The plugin must use the reviewed version";
assert lib.assertMsg (builtins.attrNames trust == [ "i-have-adhd@home-manager:hooks/hooks.json:session_start:0:0" ]) "Only the declared command hook may be trusted";
assert lib.assertMsg (lib.all (name: lib.hasInfix "name: ${name}" skills.${name}
  && configuration.programs.claude-code.skills.${name} == skills.${name}
  && configuration.programs.pi.skills.${name} == skills.${name}) [ "caveman" "ultracave" "megacave" ]) "Caveman aliases must have their companion skills";
pkgs.runCommand "dev-llm-plugins" {
  nativeBuildInputs = [ pkgs.python3 pkgs.nodejs ];
  inherit plugin;
  trustJson = builtins.toJSON trust;
} ''
  python3 - <<'PY'
import hashlib
import json
import os
import struct
from pathlib import Path

plugin = Path(os.environ['plugin'])
handler = json.loads((plugin / 'hooks/hooks.json').read_text())['hooks']['SessionStart'][0]['hooks'][0]
identity = {
    'event_name': 'session_start',
    'hooks': [{
        'type': 'command',
        'command': handler['command'],
        'timeout': 30,
        'async': False,
        'statusMessage': handler['statusMessage'],
    }],
    'matcher': 'startup|resume|clear|compact',
}
canonical = json.dumps(identity, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
expected = 'sha256:' + hashlib.sha256(canonical.encode()).hexdigest()
trust = json.loads(os.environ['trustJson'])
assert next(iter(trust.values()))['trusted_hash'] == expected
# Codex 0.165 plugin_fingerprint.rs: sorted depth-first bundle identity.
hash = hashlib.sha256(b'codex-plugin-bundle-v1')
pending = [plugin]
while pending:
    path = pending.pop()
    name = path.relative_to(plugin).as_posix() if path != plugin else ""
    if path.name in ('__pycache__', '.venv') or path.name.endswith(('.pyc', '.egg-info')):
        continue
    encoded = name.encode()
    hash.update(struct.pack('<Q', len(encoded)))
    hash.update(encoded)
    if path.is_dir():
        hash.update(b'directory')
        pending.extend(sorted(path.iterdir(), reverse=True))
    elif path.is_file() and not path.is_symlink():
        data = path.read_bytes()
        hash.update(b'file')
        hash.update(struct.pack('<Q', len(data)))
        hash.update(data)
    else:
        raise AssertionError(f'Unsupported plugin entry {path}')
content_hash = 'sha256:' + hash.hexdigest()
assert next(iter(trust.values()))['trusted_content_hash'] == content_hash, 'Upgraded plugin needs explicit content approval, not an old legacy baseline'
PY
  export CLAUDE_CONFIG_DIR="$TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  node "$plugin/hooks/always-on.mjs" > inactive
  test ! -s inactive
  touch "$CLAUDE_CONFIG_DIR/.i-have-adhd-always"
  node "$plugin/hooks/always-on.mjs" > active
  grep -F 'ADHD MODE ACTIVE (always-on)' active
  touch "$out"
''

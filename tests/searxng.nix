{ pkgs }:
let
  settings = import ../pkg/searxng/settings.nix;
  referenceCertifi = pkgs.fetchzip {
    url = "https://github.com/certifi/python-certifi/archive/refs/tags/2026.10.23.tar.gz";
    hash = "sha256-uESJgC07To+bUePmwi180SCtAzAZkmEn1UolTWpB4X0=";
  };
  searchPkgs = pkgs.extend (import ../pkg/searxng/overlay.nix);
  package = searchPkgs.callPackage ../pkg/searxng { };
  python = searchPkgs.python3.withPackages (ps: [ package ps.pyyaml ]);
  enabled = map (engine: engine.name) (builtins.filter (engine: !engine.disabled) settings.engines);
  disabled = map (engine: engine.name) (builtins.filter (engine: engine.disabled) settings.engines);
in
# BA @specified: reusable policy contains no deployment settings.
assert builtins.attrNames settings == [ "default_doi_resolver" "engines" "search" "server" "use_default_settings" ];
assert settings.use_default_settings;
assert settings.server == { method = "GET"; };
assert settings.search == {
  formats = [ "html" "json" ];
  autocomplete = "brave";
  favicon_resolver = "duckduckgo";
};
assert settings.default_doi_resolver == "sci-hub.st";
assert enabled == [ "bing" "brave" "duckduckgo" "google" "yahoo" "yandex images" "crowdview" "fynd" "gmx" "zapmeta" "ddg definitions" ];
assert disabled == [ "resulthunter" "yep" "privacywall" "yacy" "fastbot" "fireball" "qwant" "wikidata" ];
# BG @specified: the packaged DOI default is enabled without replacing other plugins.
pkgs.runCommand "searxng-policy" { nativeBuildInputs = [ python ]; } ''
  python3 - <<'PY'
from pathlib import Path
import searx
import yaml
import certifi
import base64
import hashlib
import re


def fingerprints(bundle):
    return {
        hashlib.sha256(base64.b64decode(pem)).hexdigest()
        for pem in re.findall(
            rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", bundle, re.S
        )
    }


reference = fingerprints(Path("${referenceCertifi}/certifi/cacert.pem").read_bytes())
assert len(reference) == 118
assert fingerprints(Path(certifi.where()).read_bytes()) == reference
print("Native certifi.where() uses the same CA certificates as certifi 2026.10.23")

settings = yaml.safe_load((Path(searx.__file__).parent / "settings.yml").read_text())
plugins = settings["plugins"]
assert plugins["searx.plugins.oa_doi_rewrite.SXNGPlugin"]["active"] is True
assert len(plugins) > 1
print("SearXNG DOI plugin enabled; other plugin defaults preserved")
PY
  python3 ${./searxng-config.py} -v
  touch "$out"
''

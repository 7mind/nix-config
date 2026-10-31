# searxng built from upstream master instead of the commit pinned in nixpkgs.
#
# nixpkgs tracks rolling master snapshots of searxng (version `0-unstable-…`),
# so repointing `src` is enough to ride master. Newer HTTP/browser and date
# parsing dependencies are private to SearXNG. The runtime list excludes
# cloudscraper, which is absent from upstream requirements.txt.
#
# To bump to a newer master commit: update `version`, `rev` and `hash` below.
# `hash` is the NAR hash of the fetched tree as reported by:
#   nix flake prefetch github:searxng/searxng/<rev> --json
final: prev:
let
  curlImpersonate = prev.callPackage ./curl-impersonate.nix {
    curl-impersonate = prev.curl-impersonate;
  };
  python = final.python3.override {
    packageOverrides = python-final: python-prev: {
      curl-cffi = (python-prev.curl-cffi.override {
        curl-impersonate = curlImpersonate;
      }).overridePythonAttrs (old: rec {
        version = "0.17.0";
        src = old.src.override {
          tag = "v${version}";
          hash = "sha256-1QN7gf0WPACxFgjK560M7/TA40+/zsQQ7HBCRdx6BLc=";
        };
        patches = [ ./curl-cffi-use-system-libs.patch ];
        # curl-cffi uses certifi.where(); Nix's NSS 3.131.1 CA certificates
        # match certifi 2026.10.23's bundle, independently of the version metadata.
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "certifi" ];
        nativeCheckInputs = old.nativeCheckInputs ++ [ python-final.jsonpath-ng ];
      });
    };
  };
  # Only SearXNG requires dateutil 3; do not upgrade unrelated test dependencies.
  dateutil = python.pkgs.python-dateutil.overridePythonAttrs (old: {
    version = "3.0.0";
    propagatedBuildInputs = old.propagatedBuildInputs ++ [ python.pkgs.tzdata ];
    src = prev.fetchPypi {
      pname = "python_dateutil";
      version = "3.0.0";
      hash = "sha256-fryzwpqS886v55p6SKXEVnfp4AS77sV0KsC7sAVgt6I=";
    };
  });
in
{
  searxng = (prev.searxng.override { python3 = python; }).overrideAttrs (finalAttrs: previousAttrs: {
    version = "0-unstable-2026-10-30";

    src = previousAttrs.src.override {
      rev = "1cd13d98d65a58f1126fa5bb5c77e42c0ea625f3";
      hash = "sha256-RWiS7JAcq+j9/Ge9FHkyFfXvuXgPARv6aeTUbAkw5Xc=";
    };

    passthru = (previousAttrs.passthru or { }) // {
      # Master's requirements.txt, mapped onto the python package set.
      dependencies = with python.pkgs; [
        babel
        certifi
        curl-cffi
        flask
        flask-babel
        isodate
        jinja2
        lxml
        markdown-it-py
        msgspec
        pygments
        dateutil
        pyyaml
        typer
        typing-extensions
        valkey
        whitenoise
      ];
      # toPythonModule computes this from the pre-override dependency list.
      requiredPythonModules = python.pkgs.requiredPythonModules finalAttrs.passthru.dependencies;
    };

    # nixpkgs bakes its pinned version and source rev into searx/version_frozen.py
    # at eval time (the string is already interpolated), so regenerate it here
    # for the overridden version/rev — same body as nixpkgs' preBuild.
    preBuild =
      let
        inherit (prev.lib) concatStringsSep removePrefix splitString;
        versionString = concatStringsSep "." (
          map (removePrefix "0") (builtins.tail (splitString "-" (removePrefix "0-" finalAttrs.version)))
        );
        commitAbbrev = builtins.substring 0 8 finalAttrs.src.rev;
      in
      ''
        export SEARX_DEBUG="true";

        cat > searx/version_frozen.py <<EOF
        VERSION_STRING="${versionString}+${commitAbbrev}"
        VERSION_TAG="${versionString}+${commitAbbrev}"
        DOCKER_TAG="${versionString}-${commitAbbrev}"
        GIT_URL="https://github.com/searxng/searxng"
        GIT_BRANCH="master"
        EOF
      '';
  });
}

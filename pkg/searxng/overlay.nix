# searxng built from upstream master instead of the commit pinned in nixpkgs.
#
# nixpkgs tracks rolling master snapshots of searxng (version `0-unstable-…`),
# so repointing `src` is enough to ride master. The runtime dependency list is
# replaced because upstream swapped httpx/httpx-socks/sniffio for curl_cffi
# after the commit nixpkgs pins (cloudscraper was never in requirements.txt).
#
# To bump to a newer master commit: update `version`, `rev` and `hash` below.
# `hash` is the NAR hash of the fetched tree as reported by:
#   nix flake prefetch github:searxng/searxng/<rev> --json
final: prev: {
  searxng = prev.searxng.overrideAttrs (finalAttrs: previousAttrs: {
    version = "0-unstable-2026-09-25";

    src = previousAttrs.src.override {
      rev = "487f519227f5bec68c394493f69f3d43b1135112";
      hash = "sha256-LD35VRvEpfiRSu+telJ29/S1o2GtrCJtM0ewh1i1OLo=";
    };

    passthru = (previousAttrs.passthru or { }) // {
      # Master's requirements.txt, mapped onto the python package set.
      dependencies = with final.python3.pkgs; [
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
        python-dateutil
        pyyaml
        typer
        typing-extensions
        valkey
        whitenoise
      ];
      # toPythonModule computes this from the pre-override dependency list.
      requiredPythonModules = prev.python3.pkgs.requiredPythonModules finalAttrs.passthru.dependencies;
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

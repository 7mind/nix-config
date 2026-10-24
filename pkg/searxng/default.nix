{ lib, searxng }:

# SearXNG replaces rather than merges the `plugins` map. Patch the
# packaged default so enabling one plugin does not unregister the rest.
searxng.overrideAttrs (previousAttrs: {
  patches = (previousAttrs.patches or [ ]) ++ [ ./config-engine-type.patch ];
  postPatch = (previousAttrs.postPatch or "") + ''
    substituteInPlace searx/settings.yml \
      --replace-fail \
      ${lib.escapeShellArg "  searx.plugins.oa_doi_rewrite.SXNGPlugin:\n    active: false"} \
      ${lib.escapeShellArg "  searx.plugins.oa_doi_rewrite.SXNGPlugin:\n    active: true"}
  '';
})

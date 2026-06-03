# Pi `pi-xai` extension, vendored with one constant patched.
#
# Upstream `xai-provider.ts` hardcodes `contextWindow: 131072` (128k, the old
# Grok 4/4.1 figure) for all three Grok Build models it registers. The Grok
# Build Coding Plan model (Grok Build 0.1) actually exposes 256k — Pi's own
# bundled model table agrees (grok-build-0.1 → 256000) — so the stale 128k makes
# Pi report `%/131k` and auto-compact prematurely, under-using the context.
#
# We can't fix this from settings (`modelOverrides` only applies to *built-in*
# providers, and `grok-build` is registered at runtime by this extension), nor
# from a second extension (re-registering the provider can't preserve pi-xai's
# dynamic OAuth token resolver). So we vendor the source and bump the constant.
#
# Pi loads this via `settings.packages = [ "${pi-xai-patched}" ]` — a local-path
# package spec — and runs `npm install <storepath> --prefix ~/.pi/agent/npm`,
# which installs the patched source plus its `typebox` dependency. The package
# name/provider id stays `grok-build`, so existing OAuth state is unaffected.
#
# Bump procedure: update `version` + `hash` (and re-confirm the constant still
# reads `131072` in the new tag's xai-provider.ts).
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  jq,
}:
let
  # pi-xai's sole runtime dependency (zero transitive deps). Pi installs this
  # package as a local-path spec, which npm SYMLINKS into ~/.pi/agent/npm; node
  # then resolves `import "typebox"` from the store realpath, so the dep must
  # live in THIS output's node_modules (a walk-up from the store path can't
  # reach the consuming prefix). The prebuilt npm tarball unpacks to `package/`.
  typeboxTarball = fetchurl {
    url = "https://registry.npmjs.org/typebox/-/typebox-1.1.39.tgz";
    hash = "sha256-/tOMRATVJQjp/jrzvr9WwKI0e8Ased9g1Z+baGYsjNs=";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-xai-patched";
  version = "0.8.5";

  src = fetchFromGitHub {
    owner = "luxus";
    repo = "pi-xai";
    tag = "v${finalAttrs.version}";
    hash = "sha256-jZQuGeDzWohBK5nZCfOymOaZen2bVCd/Rzt13yvFLlk=";
  };

  # Pure TypeScript extension — Pi runs it through jiti, nothing to compile.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    cp -r . "$out"
    # Bump all three Grok Build models from the stale 128k to the real 256k.
    substituteInPlace "$out/xai-provider.ts" \
      --replace-fail 'contextWindow: 131072' 'contextWindow: 256000'
    # Pi installs this as a local-path package via `npm install <dir>`, which
    # (unlike a registry tarball) runs lifecycle scripts. Upstream's
    # `prepare: husky` then fails (husky is a devDep, absent under --omit=dev)
    # and aborts the install before deps resolve. None of the scripts are
    # needed at runtime, so drop them.
    jq 'del(.scripts)' "$out/package.json" > "$out/package.json.tmp"
    mv "$out/package.json.tmp" "$out/package.json"
    # Bundle the runtime dep so it resolves through the symlink (see note above).
    mkdir -p "$out/node_modules/typebox"
    tar xzf ${typeboxTarball} -C "$out/node_modules/typebox" --strip-components=1
    runHook postInstall
  '';

  meta = {
    description = "pi-xai Pi extension with the Grok Build context window patched 128k->256k";
    homepage = "https://github.com/luxus/pi-xai";
    license = lib.licenses.mit;
  };
})

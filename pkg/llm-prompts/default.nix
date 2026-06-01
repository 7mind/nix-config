{
  lib,
  stdenvNoCC,
  yq-go,
}:
let
  baseContext = builtins.readFile ./context.md;

  skillNames = builtins.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./skills)
  );

  mkSkill =
    name:
    "---\n"
    + builtins.readFile (./skills + "/${name}/meta.yaml")
    + "---\n\n"
    + builtins.readFile (./skills + "/${name}/content.md");

  # Read a directory of `*.md` files into a { "<basename>" = "<body>"; }
  # attrset of inline strings. IFD-free: only readDir/readFile at eval time,
  # never a build-then-read. Returns {} when the directory is absent, so the
  # commands/agents contribution surfaces exist before any files do.
  mkMdAssets =
    dir:
    if !(builtins.pathExists dir) then
      { }
    else
      lib.mapAttrs' (
        fname: _: lib.nameValuePair (lib.removeSuffix ".md" fname) (builtins.readFile (dir + "/${fname}"))
      ) (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir dir));

  contextWithEnvContent =
    builtins.toFile "context-with-env.md"
      (baseContext + "\n\n" + builtins.readFile ./skills/environment/content.md);

  validated = stdenvNoCC.mkDerivation {
    name = "llm-prompts";
    src = ./.;

    nativeBuildInputs = [ yq-go ];

    doCheck = true;
    checkPhase = ''
      bash validate-skills.sh skills/*/meta.yaml
    '';

    installPhase = ''
      mkdir -p $out
      ln -s ${contextWithEnvContent} $out/context-with-env.md
    '';

    meta = with lib; {
      description = "LLM agent prompts and skills with build-time validation";
      license = [ licenses.mit ];
      maintainers = with maintainers; [ pshirshov ];
    };
  };
in
{
  # Canonical LLM asset bundle — the same cross-repo shape consumed by
  # smind.hm.dev.llm.assetBundles and produced by ledger.llmAssets:
  #   { skills; commands; agents; context; }
  #
  # All values are inline strings (skills/commands/agents) or string
  # fragments (context), never store paths — so consumer modules don't call
  # `lib.pathIsDirectory` on a store path. That stat forces IFD realization
  # at eval time and fails when Darwin configs are evaluated on Linux (and
  # vice versa). meta.yaml validation still runs at build time via
  # `validated`, pulled into the build graph transitively through
  # `contextWithEnvFile`.
  llmAssets = {
    skills = lib.genAttrs skillNames mkSkill;
    # Slash commands and subagent definitions, same inline-string contract
    # as skills. Empty until files land under ./commands and ./agents.
    commands = mkMdAssets ./commands;
    agents = mkMdAssets ./agents;
    # Base global context fragment (CLAUDE.md/AGENTS.md). The environment
    # skill is delivered separately via skills/ (and composed into
    # contextWithEnvFile for agents without skill support).
    context = [ baseContext ];
  };

  # Pre-composed context file for agents without skill support (Copilot, Vibe).
  contextWithEnvFile = "${validated}/context-with-env.md";

  # Build-time-validated derivation (skills meta.yaml checks).
  package = validated;
}

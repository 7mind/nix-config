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
  inherit baseContext;

  # Skills delivered as inline strings so consumer modules (claude-code,
  # codex, opencode) don't call `lib.pathIsDirectory` on a store path —
  # that stat forces IFD realization at eval time and fails when Darwin
  # configs are evaluated on Linux (and vice versa). Validation of
  # meta.yaml still runs at build time via `validated`, pulled into the
  # build graph transitively through `contextWithEnvFile`.
  skills = lib.genAttrs skillNames mkSkill;

  # Pre-composed context file for agents without skill support (Copilot, Vibe)
  contextWithEnvFile = "${validated}/context-with-env.md";

  package = validated;
}

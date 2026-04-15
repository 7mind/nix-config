{
  lib,
  stdenvNoCC,
  yq-go,
}:
let
  baseContext = builtins.readFile ./context.md;

  validated = stdenvNoCC.mkDerivation {
    name = "llm-prompts";
    src = ./.;

    nativeBuildInputs = [ yq-go ];

    doCheck = true;
    checkPhase = ''
      bash validate-skills.sh skills/*/meta.yaml
    '';

    installPhase = ''
      # Generate SKILL.md for each skill from meta.yaml + content.md
      for skill_dir in skills/*/; do
        skill_name=$(basename "$skill_dir")
        mkdir -p "$out/skills/$skill_name"
        {
          echo '---'
          cat "$skill_dir/meta.yaml"
          echo '---'
          echo
          cat "$skill_dir/content.md"
        } > "$out/skills/$skill_name/SKILL.md"
      done

      # Pre-composed context for agents without skill support (Copilot, Vibe)
      cat context.md > $out/context-with-env.md
      printf '\n\n' >> $out/context-with-env.md
      cat skills/environment/content.md >> $out/context-with-env.md
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

  # Validated skill directories for agents with skill support
  # (Claude Code, Codex, Gemini CLI, OpenCode)
  skills = {
    baboon = "${validated}/skills/baboon";
    environment = "${validated}/skills/environment";
    tass = "${validated}/skills/tass";
  };

  # Pre-composed context file for agents without skill support (Copilot, Vibe)
  contextWithEnvFile = "${validated}/context-with-env.md";

  package = validated;
}

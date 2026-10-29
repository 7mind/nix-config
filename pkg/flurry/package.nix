{ lib, python3Packages, git, nix, gh, glab, openssh, makeWrapper }:

python3Packages.buildPythonApplication {
  pname = "flurry";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      lib.cleanSourceFilter path type
      && !(lib.elem (baseNameOf path) [ ".worktrees" ".flurry" "__pycache__" "flurry.local.toml" "build" "dist" ])
      && !(lib.hasSuffix ".egg-info" (baseNameOf path));
  };
  pyproject = true;
  build-system = [ python3Packages.setuptools ];
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ git ];
  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export FLURRY_REAL_NIX=0
    ${python3Packages.python.interpreter} -m unittest discover -s tests -v
    runHook postCheck
  '';
  postFixup = ''
    wrapProgram "$out/bin/flurry" --prefix PATH : ${lib.makeBinPath [ git nix gh glab openssh ]}
  '';
  meta = {
    description = "A little swarm of flakes: multi-repository Nix maintenance";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "flurry";
  };
}

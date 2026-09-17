{ lib, buildNpmPackage, nodejs_24 }:

buildNpmPackage {
  pname = "mqtt-controller-frontend";
  version = "0.1.0";
  nodejs = nodejs_24;
  src = lib.cleanSourceWith {
    src = ./frontend;
    filter = name: type:
      !(type == "directory" && builtins.elem (baseNameOf name) [
        "node_modules" "dist" "test-results" "playwright-report"
      ]);
  };
  npmDepsHash = "sha256-p9phcqpBr60o1snHyEwufx4s/c4Oy2i8R440ZgkKMU8=";
  npmBuildScript = "build";
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';
  meta = {
    description = "TypeScript dashboard for the MQTT controller";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}

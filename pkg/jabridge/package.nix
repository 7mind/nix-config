{
  lib,
  buildGo127Module,
  fetchFromGitHub,
  installShellFiles,
  makeWrapper,
  pipewire,
  wireplumber,
  systemd,
  dfu-util,
  bashInteractive,
  coreutils,
}:

buildGo127Module rec {
  pname = "jabridge";
  version = "1.5.0";

  src = fetchFromGitHub {
    owner = "Watchdog0x";
    repo = "jabridge";
    rev = "108d67b669b587d05c44df4035ace5557121a874";
    hash = "sha256-n5JKf1w99qaRZR+XnepVCnjXaLapxZcUianlDO0ICVM=";
  };

  vendorHash = "sha256-4WiNhTIAEwgiI/4BFXpDHilGKr7zhhlPQzhgsSEAROk=";
  env.CGO_ENABLED = 0;
  subPackages = [ "cmd/jabridge" ];
  nativeBuildInputs = [
    installShellFiles
    makeWrapper
  ];
  nativeCheckInputs = [ bashInteractive ];

  postPatch = ''
    substituteInPlace daemon/pipewire/audio_recovery_process_test.go \
      --replace-fail /bin/sleep ${lib.getExe' coreutils "sleep"}
  '';

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/Watchdog0x/jabridge/internal/buildinfo.Version=${version}"
    "-X=github.com/Watchdog0x/jabridge/internal/buildinfo.SelfUpdate=disabled"
    "-X=github.com/Watchdog0x/jabridge/internal/buildinfo.Setup=disabled"
  ];

  checkPhase = ''
    runHook preCheck
    export JABRIDGE_TEST_EXPECT_SELF_UPDATE=disabled
    export JABRIDGE_TEST_EXPECT_SETUP=disabled
    go test -ldflags="''${ldflags[*]}" ./...
    runHook postCheck
  '';

  postInstall = ''
    installShellCompletion --bash internal/completion/jabridge.bash
    install -Dm644 internal/assets/70-jabridge.rules $out/lib/udev/rules.d/70-jabridge.rules
    install -Dm644 internal/assets/jabridge.service $out/lib/systemd/user/jabridge.service
    substituteInPlace $out/lib/systemd/user/jabridge.service \
      --replace-fail "/usr/bin/env jabridge" "$out/bin/jabridge"
    wrapProgram $out/bin/jabridge \
      --prefix PATH : ${
        lib.makeBinPath [
          pipewire
          wireplumber
          systemd
          dfu-util
        ]
      }
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$(mktemp -d)
    $out/bin/jabridge --version | grep -F '${version}'
    if $out/bin/jabridge update >update.log 2>&1; then
      echo "Self-update unexpectedly enabled" >&2
      exit 1
    fi
    grep -F 'package manager' update.log
    if $out/bin/jabridge setup >setup.log 2>&1; then
      echo "Imperative setup unexpectedly enabled" >&2
      exit 1
    fi
    grep -F 'package manager' setup.log
    grep -Fx "ExecStart=$out/bin/jabridge --daemon" $out/lib/systemd/user/jabridge.service
    test -s $out/lib/udev/rules.d/70-jabridge.rules
    test -s $out/share/bash-completion/completions/jabridge.bash
    runHook postInstallCheck
  '';

  meta = {
    description = "Community Jabra headset and dongle manager for Linux";
    homepage = "https://github.com/Watchdog0x/jabridge";
    changelog = "https://github.com/Watchdog0x/jabridge/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "jabridge";
    platforms = lib.platforms.linux;
  };
}

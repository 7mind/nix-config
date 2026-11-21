{
  lib,
  buildGoModule,
  pkg-config,
  sqlite,
}:

buildGoModule {
  pname = "linphone-file-transfer";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  vendorHash = null;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ sqlite ];
  env.CGO_ENABLED = 1;

  meta = {
    description = "Linphone HTTP attachment storage and provisioning server";
    mainProgram = "linphone-file-transfer";
    platforms = lib.platforms.linux;
  };
}

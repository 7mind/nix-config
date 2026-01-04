{ lib
, fractal
, rustPlatform
, dbus
}:

let
  trayModule = ./tray.rs;
  cargoPatch = ./cargo.patch;
  cargoLockPatch = ./cargo-lock.patch;
  allPatches = [ cargoPatch cargoLockPatch ];
in
fractal.overrideAttrs (old: {
  pname = "fractal-tray";

  patches = (old.patches or []) ++ allPatches;

  postPatch = (old.postPatch or "") + ''
    # Add tray module
    cp ${trayModule} src/tray.rs

    # Add mod tray; to main.rs after mod system_settings;
    sed -i '/^mod system_settings;/a mod tray;' src/main.rs

    # Add tray import to application.rs
    sed -i '/use crate::{/,/};/s/toast,/tray::{spawn_tray, TrayCommand},\n    toast,/' src/application.rs

    # Add tray initialization after session restore in application.rs
    sed -i '/session_list.restore_sessions().await;/,/}\s*\]);/s/}\s*\]);/}\
            });\
\
            \/\/ Initialize system tray\
            spawn!(clone!(\
                #[weak(rename_to = obj)]\
                self.obj(),\
                async move {\
                    let mut rx = spawn_tray().await;\
                    while let Some(cmd) = rx.recv().await {\
                        match cmd {\
                            TrayCommand::Show => { obj.present_main_window(); }\
                            TrayCommand::Quit => { obj.quit(); }\
                        }\
                    }\
                }\
            ));/' src/application.rs

    # Modify window.rs to hide on close instead of quit
    sed -i 's/glib::Propagation::Proceed/self.obj().set_visible(false); glib::Propagation::Stop/' src/window.rs
  '';

  # Need to update cargo vendor hash since we added ksni dependency
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (old) src;
    patches = allPatches;
    hash = "sha256-N1pjx3O0fJ67sMstTzk/TIuBAVlzEuaz/dHNha8E1BA=";
  };

  buildInputs = old.buildInputs ++ [ dbus ];

  meta = old.meta // {
    description = old.meta.description + " (with system tray support)";
  };
})

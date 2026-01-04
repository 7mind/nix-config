{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

let
  fractal-kdocker = pkgs.runCommand "fractal-kdocker"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta.mainProgram = "fractal";
    } ''
        mkdir -p $out/bin $out/share

        # Create wrapper that launches fractal via kdocker (minimized to tray)
        # Use icon name (not path) so kdocker looks it up from theme
        cat > $out/bin/fractal <<EOF
    #!/usr/bin/env bash
    exec ${pkgs.kdocker}/bin/kdocker -q -o -l -i org.gnome.Fractal ${pkgs.fractal}/bin/fractal "\$@"
    EOF
        chmod +x $out/bin/fractal

        # Copy desktop file with updated Exec
        mkdir -p $out/share/applications
        sed "s|Exec=fractal|Exec=$out/bin/fractal|g" ${pkgs.fractal}/share/applications/org.gnome.Fractal.desktop > $out/share/applications/org.gnome.Fractal.desktop

        # Symlink icons
        ln -s ${pkgs.fractal}/share/icons $out/share/icons
  '';
in
{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

  home.packages = [
    pkgs.kdocker
    fractal-kdocker
  ];

  smind.hm = {
    roles.desktop = true;
    wezterm.fontSize = 11;
    vscodium.fontSize = 14;
    ghostty.enable = true;
    ghostty.fontSize = 11;

    # Resource-limited Electron apps
    electron-wrappers = {
      enable = true;
      cpuQuota = "200%";
      cpuWeight = 70;
      memoryMax = "4G";
      slack.enable = true;
      element.enable = true;
    };

    autostart.programs = [
      # {
      #   name = "element-main";
      #   exec = "${config.home.profileDirectory}/bin/element-desktop";
      # }
      {
        name = "slack";
        exec = "${config.home.profileDirectory}/bin/slack";
      }
      {
        name = "fractal";
        exec = "${config.home.profileDirectory}/bin/fractal";
      }
    ];
  };
}

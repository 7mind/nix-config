final: prev:
let
  uuid = "gsconnect@andyholmes.github.io";
  extension = prev.gnome51Extensions.${uuid};
  patched = assert extension.version == "74"; extension.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace shell/tooltip.js \
        --replace-fail 'y_align: St.Align.START,' 'y_align: Clutter.ActorAlign.START,'
    '';
  });
in
{
  gnome51Extensions = prev.gnome51Extensions // { ${uuid} = patched; };
  gnomeExtensions = prev.gnomeExtensions // { gsconnect = patched; };
}

final: prev:
let
  uuid = "dim-completed-calendar-events@marcinjahn.com";
in
{
  gnome51Extensions = prev.gnome51Extensions // {
    ${uuid} = prev.gnome50Extensions.${uuid}.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.jq final.python3 ];
      postPatch = (old.postPatch or "") + ''
        jq '.["shell-version"] |= (. + ["51"] | unique)' metadata.json > metadata.json.tmp
        mv metadata.json.tmp metadata.json
        python3 - <<'PY'
        from pathlib import Path

        path = Path("extension.js")
        source = path.read_text()
        replacements = [
            ("import St from 'gi://St';\n\n", "import St from 'gi://St';\nimport Clutter from 'gi://Clutter';\n\n"),
            ("vertical: true,", "orientation: Clutter.Orientation.VERTICAL,"),
        ]
        for before, after in replacements:
            assert source.count(before) + source.count(after) == 1, (before, after)
            source = source.replace(before, after)
        path.write_text(source)
        PY
      '';
    });
  };
}

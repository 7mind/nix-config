import os
from pathlib import Path
import re
import subprocess
import sys

shell, mutter, gjs, script, *sources = map(Path, sys.argv[1:])
wrapper = (shell / "bin/gnome-shell").read_bytes().decode(errors="ignore")
paths = re.findall(r"--prefix 'GI_TYPELIB_PATH' ':' '([^']+)'", wrapper)
assert paths, "GNOME Shell wrapper must declare its pinned typelib dependencies"
major = shell.name.rsplit("-", 1)[1].split(".")[0]
env = dict(os.environ)
env["GI_TYPELIB_PATH"] = ":".join([
    str(shell / "lib/gnome-shell"), str(mutter / f"lib/mutter-{major}"), *paths,
])
env["LD_LIBRARY_PATH"] = ":".join([
    str(shell / "lib/gnome-shell"), str(mutter / f"lib/mutter-{major}"),
])
result = subprocess.run([str(gjs), str(script), major, *map(str, sources)], env=env)
raise SystemExit(result.returncode)

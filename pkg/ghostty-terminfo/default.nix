{
  ghostty,
  ncurses,
  python3,
  runCommand,
  writeText,
}:

runCommand "ghostty-terminfo-${ghostty.version}"
  {
    nativeBuildInputs = [ ncurses ];
  }
  ''
    ${python3.interpreter} ${writeText "gen-ghostty-ti.py" ''
      import re, sys
      with open(sys.argv[1]) as f:
          content = f.read()
      names_match = re.search(r'\.names\s*=\s*&\.\{(.*?)\}', content, re.DOTALL)
      names = re.findall(r'"([^"]+)"', names_match.group(1))
      caps = []
      for line in content.split('\n'):
          m = re.search(r'\.name\s*=\s*"([^"]+)"', line)
          if not m:
              continue
          name = m.group(1)
          if '.boolean' in line:
              caps.append(f"\t{name},")
          elif '.canceled' in line:
              caps.append(f"\t{name}@,")
          elif '.numeric' in line:
              nm = re.search(r'\.numeric\s*=\s*(\d+)', line)
              caps.append(f"\t{name}#{nm.group(1)},")
          elif '.string' in line:
              sm = re.search(r'\.string\s*=\s*"([^"]*)"', line)
              s = sm.group(1).replace('\\\\', '\\')
              caps.append(f"\t{name}={s},")
      print('|'.join(names) + ',')
      print('\n'.join(caps))
    ''} ${ghostty.src}/src/terminfo/ghostty.zig > ghostty.ti
    mkdir -p $out/share/terminfo
    tic -x -o $out/share/terminfo ghostty.ti
  ''

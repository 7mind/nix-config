{ lib, writeShellApplication, tmux, reptyr, procps, gnugrep, gawk, coreutils, sudo }:

writeShellApplication {
  name = "reattach-llm";
  runtimeInputs = [
    tmux
    reptyr
    procps
    gnugrep
    gawk
    coreutils
    sudo
  ];
  text = builtins.readFile ./reattach-llm.sh;

  meta = with lib; {
    description = "Reattach Claude, Codex, and Gemini terminals into the llm tmux session";
    license = [ licenses.mit ];
    maintainers = with maintainers; [ pshirshov ];
    platforms = platforms.linux;
    mainProgram = "reattach-llm";
  };
}

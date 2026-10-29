from __future__ import annotations

import json
from dataclasses import dataclass
from enum import Enum
from typing import Mapping, TextIO


ANSI_PREFIX = "\x1b["
ANSI_RESET = f"{ANSI_PREFIX}0m"
JSON_INDENT = 2


class ColourMode(str, Enum):
    AUTO = "auto"
    ALWAYS = "always"
    NEVER = "never"


class Tone(str, Enum):
    PLAIN = ""
    NAME = "1;36"
    INFO = "36"
    SUCCESS = "32"
    WARNING = "33"
    ERROR = "31"
    MUTED = "2"


@dataclass(frozen=True)
class Console:
    stdout: TextIO
    stderr: TextIO
    environment: Mapping[str, str]
    colour: ColourMode
    machine_readable: bool

    def _style(self, text: str, tone: Tone, stream: TextIO) -> str:
        if tone == Tone.PLAIN or self.machine_readable or self.colour == ColourMode.NEVER:
            return text
        if self.colour == ColourMode.AUTO:
            if self.environment.get("NO_COLOR") or self.environment.get("TERM") == "dumb":
                return text
            if not stream.isatty():
                return text
        return f"{ANSI_PREFIX}{tone.value}m{text}{ANSI_RESET}"

    def style(self, text: str, tone: Tone) -> str:
        return self._style(text, tone, self.stdout)

    def line(self, text: str, tone: Tone) -> None:
        print(self.style(text, tone), file=self.stdout)

    def diagnostic(self, text: str, tone: Tone) -> None:
        print(self._style(text, tone, self.stderr), file=self.stderr)

    def document(self, data: object) -> None:
        self.line(json.dumps(data, indent=JSON_INDENT, sort_keys=True), Tone.INFO)

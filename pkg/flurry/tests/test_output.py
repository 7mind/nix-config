import io
import itertools
import json
import unittest
from dataclasses import FrozenInstanceError

from flurry.output import ColourMode, Console, Tone


class TerminalStream(io.StringIO):
    def __init__(self, terminal: bool):
        super().__init__()
        self.terminal = terminal

    def isatty(self) -> bool:
        return self.terminal


class ConsoleTests(unittest.TestCase):
    def test_colour_policy_uses_each_stream_independently(self):
        environments = (
            ({}, True),
            ({"NO_COLOR": ""}, True),
            ({"NO_COLOR": "1"}, False),
            ({"NO_COLOR": "0"}, False),
            ({"TERM": "dumb"}, False),
            ({"TERM": "xterm-256color"}, True),
            ({"NO_COLOR": "", "TERM": "dumb"}, False),
            ({"NO_COLOR": "1", "TERM": "dumb"}, False),
        )
        for colour, stdout_tty, stderr_tty, machine_readable, policy in itertools.product(
            ColourMode, (False, True), (False, True), (False, True), environments
        ):
            environment, auto_allowed = policy
            with self.subTest(colour=colour, stdout_tty=stdout_tty, stderr_tty=stderr_tty,
                              machine_readable=machine_readable, environment=environment):
                stdout = TerminalStream(stdout_tty)
                stderr = TerminalStream(stderr_tty)
                console = Console(stdout, stderr, environment, colour, machine_readable)
                expected = []
                for terminal in (stdout_tty, stderr_tty):
                    styled = not machine_readable and (
                        colour == ColourMode.ALWAYS
                        or (colour == ColourMode.AUTO and auto_allowed and terminal)
                    )
                    expected.append("\x1b[36mmessage\x1b[0m" if styled else "message")
                self.assertEqual(console.style("message", Tone.INFO), expected[0])
                self.assertEqual(stdout.getvalue(), "")
                console.line("message", Tone.INFO)
                console.diagnostic("message", Tone.INFO)
                self.assertEqual(stdout.getvalue(), expected[0] + "\n")
                self.assertEqual(stderr.getvalue(), expected[1] + "\n")

    def test_tones_have_exact_sequences_and_resets(self):
        tones = (
            (Tone.PLAIN, ""),
            (Tone.NAME, "1;36"),
            (Tone.INFO, "36"),
            (Tone.SUCCESS, "32"),
            (Tone.WARNING, "33"),
            (Tone.ERROR, "31"),
            (Tone.MUTED, "2"),
        )
        for tone, sequence in tones:
            with self.subTest(tone=tone):
                stdout = TerminalStream(False)
                stderr = TerminalStream(False)
                console = Console(stdout, stderr, {}, ColourMode.ALWAYS, False)
                expected = f"\x1b[{sequence}mmessage\x1b[0m" if sequence else "message"
                self.assertEqual(console.style("message", tone), expected)
                console.line("message", tone)
                console.line("plain", Tone.PLAIN)
                console.diagnostic("message", tone)
                self.assertEqual(stdout.getvalue(), expected + "\nplain\n")
                self.assertEqual(stderr.getvalue(), expected + "\n")

    def test_user_content_including_ansi_is_preserved(self):
        text = "  path with spaces\t\x1b[35muser colour\x1b[0m\nnext line  "
        for colour in ColourMode:
            with self.subTest(colour=colour):
                stdout = TerminalStream(True)
                stderr = TerminalStream(True)
                console = Console(stdout, stderr, {}, colour, False)
                expected = text if colour == ColourMode.NEVER else f"\x1b[31m{text}\x1b[0m"
                self.assertEqual(console.style(text, Tone.PLAIN), text)
                self.assertEqual(console.style(text, Tone.ERROR), expected)
                console.line(text, Tone.ERROR)
                console.diagnostic(text, Tone.ERROR)
                self.assertEqual(stdout.getvalue(), expected + "\n")
                self.assertEqual(stderr.getvalue(), expected + "\n")

    def test_machine_readable_documents_are_plain_sorted_indented_json(self):
        data = {"z": [2, 1], "a": {"z": False, "a": "value"}}
        expected = ('{\n  "a": {\n    "a": "value",\n    "z": false\n  },\n'
                    '  "z": [\n    2,\n    1\n  ]\n}\n')
        for colour, terminal in itertools.product(ColourMode, (False, True)):
            with self.subTest(colour=colour, terminal=terminal):
                stdout = TerminalStream(terminal)
                stderr = TerminalStream(terminal)
                console = Console(stdout, stderr, {}, colour, True)
                console.document(data)
                self.assertEqual(stdout.getvalue(), expected)
                self.assertEqual(json.loads(stdout.getvalue()), data)
                self.assertNotIn("\x1b", stdout.getvalue())
                self.assertEqual(stderr.getvalue(), "")

    def test_human_document_uses_info_tone(self):
        stdout = TerminalStream(False)
        console = Console(stdout, TerminalStream(False), {}, ColourMode.ALWAYS, False)
        console.document({"a": 1})
        self.assertEqual(stdout.getvalue(), '\x1b[36m{\n  "a": 1\n}\x1b[0m\n')

    def test_console_configuration_is_frozen(self):
        console = Console(TerminalStream(False), TerminalStream(False), {}, ColourMode.AUTO, False)
        with self.assertRaises(FrozenInstanceError):
            console.colour = ColourMode.ALWAYS

    def test_colour_mode_values(self):
        self.assertEqual([mode.value for mode in ColourMode], ["auto", "always", "never"])

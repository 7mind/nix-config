#!/usr/bin/env python3
"""
Terminal Theme Accessibility Analyzer

Analyzes terminal color themes for WCAG contrast compliance and generates
visual mockups to preview themes with 24-bit true colors.

Usage:
    python theme-analyzer.py              # Interactive mode
    python theme-analyzer.py --export     # Export themes to ./themes/
    python theme-analyzer.py --help       # Show help
"""

import os
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.layout import Layout
from rich.text import Text
from rich.style import Style
from rich import box


@dataclass
class Theme:
    """Terminal color theme with 16 ANSI colors."""

    name: str
    colors: dict[int, str]  # 0-15 -> hex color

    def fg(self, idx: int) -> str:
        """Get foreground escape sequence using 24-bit true color."""
        hex_color = self.colors.get(idx, "#ffffff")
        r, g, b = hex_to_rgb(hex_color)
        return f"\033[38;2;{r};{g};{b}m"

    def bg(self, idx: int) -> str:
        """Get background escape sequence using 24-bit true color."""
        hex_color = self.colors.get(idx, "#000000")
        r, g, b = hex_to_rgb(hex_color)
        return f"\033[48;2;{r};{g};{b}m"

    def to_ghostty(self) -> str:
        """Export theme in Ghostty format."""
        lines = [f"# {self.name}", "#"]
        for i in range(16):
            lines.append(f"palette = {i}={self.colors[i]}")

        # Add standard theme properties
        lines.append("")
        lines.append(f"background = {self.colors[0]}")
        lines.append(f"foreground = {self.colors[7]}")
        lines.append("")
        lines.append(f"cursor-color = {self.colors[11]}")  # bright yellow
        lines.append(f"cursor-text = {self.colors[0]}")
        lines.append("")
        lines.append(f"selection-background = {self.colors[4]}")
        lines.append("selection-foreground = #ffffff")

        return "\n".join(lines)

    def save_ghostty(self, themes_dir: Path):
        """Save theme as Ghostty theme file."""
        themes_dir.mkdir(parents=True, exist_ok=True)
        # Create safe filename
        safe_name = self.name.replace(" ", "-").replace("/", "-").replace("(", "").replace(")", "")
        filepath = themes_dir / safe_name
        filepath.write_text(self.to_ghostty())
        return filepath


# ANSI color names
COLOR_NAMES = {
    0: "black", 1: "red", 2: "green", 3: "yellow",
    4: "blue", 5: "magenta", 6: "cyan", 7: "white",
    8: "br.blk", 9: "br.red", 10: "br.grn", 11: "br.yel",
    12: "br.blu", 13: "br.mag", 14: "br.cyn", 15: "br.wht",
}

COLOR_NAMES_LONG = {
    0: "black", 1: "red", 2: "green", 3: "yellow",
    4: "blue", 5: "magenta", 6: "cyan", 7: "white",
    8: "br.black", 9: "br.red", 10: "br.green", 11: "br.yellow",
    12: "br.blue", 13: "br.magenta", 14: "br.cyan", 15: "br.white",
}

RESET = "\033[0m"


def hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    """Convert hex color to RGB tuple."""
    h = hex_color.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def relative_luminance(hex_color: str) -> float:
    """Calculate relative luminance per WCAG 2.1 specification."""
    r, g, b = hex_to_rgb(hex_color)

    def linearize(c: int) -> float:
        c_srgb = c / 255
        if c_srgb <= 0.03928:
            return c_srgb / 12.92
        return ((c_srgb + 0.055) / 1.055) ** 2.4

    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)


def contrast_ratio(c1: str, c2: str) -> float:
    """Calculate WCAG contrast ratio between two colors."""
    l1 = relative_luminance(c1)
    l2 = relative_luminance(c2)
    lighter = max(l1, l2)
    darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


# =============================================================================
# Theme Definitions
# =============================================================================

ORIGINAL = Theme(
    name="Original Pastel Dark",
    colors={
        0: "#4f4f4f", 1: "#ff6c60", 2: "#a8ff60", 3: "#ffffb6",
        4: "#96cbfe", 5: "#ff73fd", 6: "#c6c5fe", 7: "#eeeeee",
        8: "#7c7c7c", 9: "#ffb6b0", 10: "#ceffac", 11: "#ffffcc",
        12: "#b5dcff", 13: "#ff9cfe", 14: "#dfdffe", 15: "#ffffff",
    },
)

WCAG_V2_2 = Theme(
    name="WCAG Pastel Dark v2.2 (OKLCH)",
    colors={
        0: "#000000", 1: "#de000c", 2: "#00732a", 3: "#9f8c00",
        4: "#004cfe", 5: "#c808ce", 6: "#1a9b9c", 7: "#bfbfbf",
        8: "#404040", 9: "#ffb4a9", 10: "#a8ffb4", 11: "#fff4b4",
        12: "#b4cdff", 13: "#ffb4ff", 14: "#b4fffe", 15: "#ffffff",
    },
)

WCAG_V2_5 = Theme(
    name="WCAG Pastel Dark v2.5 (Golden)",
    colors={
        0: "#000000", 1: "#ff1d3a", 2: "#009e25", 3: "#c8a000",
        4: "#1767ff", 5: "#c900d0", 6: "#00909f", 7: "#bfbfbf",
        8: "#404040", 9: "#ffb4af", 10: "#b4ffb4", 11: "#ffffb4",
        12: "#b4cfff", 13: "#ffb4ff", 14: "#b4f4ff", 15: "#ffffff",
    },
)

WEZ = Theme(
    name="Wez",
    colors={
        0: "#000000", 1: "#cc5555", 2: "#55cc55", 3: "#cdcd55",
        4: "#5555cc", 5: "#cc55cc", 6: "#7acaca", 7: "#cccccc",
        8: "#555555", 9: "#ff5555", 10: "#55ff55", 11: "#ffff55",
        12: "#5555ff", 13: "#ff55ff", 14: "#55ffff", 15: "#ffffff",
    },
)

SYNTHWAVE = Theme(
    name="Synthwave",
    colors={
        0: "#000000", 1: "#f6188f", 2: "#1ebb2b", 3: "#fdf834",
        4: "#2186ec", 5: "#f85a21", 6: "#12c3e2", 7: "#ffffff",
        8: "#7f7094", 9: "#f841a0", 10: "#25c141", 11: "#fdf454",
        12: "#2f9ded", 13: "#f97137", 14: "#19cde6", 15: "#ffffff",
    },
)

NOCTURNAL_WINTER = Theme(
    name="Nocturnal Winter",
    colors={
        0: "#0d0d17", 1: "#f12d52", 2: "#09cd7e", 3: "#f5f17a",
        4: "#3182e0", 5: "#ff2b6d", 6: "#09c87a", 7: "#fcfcfc",
        8: "#4d4d4d", 9: "#f16d86", 10: "#0ae78d", 11: "#fffc67",
        12: "#6096ff", 13: "#ff78a2", 14: "#0ae78d", 15: "#ffffff",
    },
)

THEMES = [ORIGINAL, WCAG_V2_2, WCAG_V2_5, WEZ, SYNTHWAVE, NOCTURNAL_WINTER]


# =============================================================================
# Analysis Functions using Rich
# =============================================================================

def get_contrast_color(cr: float) -> str:
    """Get color for contrast ratio display."""
    if cr >= 4.5:
        return "green"
    elif cr >= 3.0:
        return "yellow"
    return "red"


def get_contrast_status(cr: float) -> str:
    """Get status string for contrast ratio."""
    if cr >= 4.5:
        return "[green]✓ AA[/]"
    elif cr >= 3.0:
        return "[yellow]~ OK[/]"
    return "[red]✗ Low[/]"


def create_palette_table(theme: Theme, console: Console) -> Table:
    """Create the optimized palette table like CUDA optimizer output."""
    bg_color = theme.colors[0]

    table = Table(title="Optimized Palette", box=box.SIMPLE_HEAD, show_header=True)
    table.add_column("#", style="dim", width=3)
    table.add_column("Name", width=10)
    table.add_column("Hex", width=8)
    table.add_column("Swatch", width=6)
    table.add_column("on Black", width=12)
    table.add_column("Status", width=8)

    for i in range(16):
        color = theme.colors[i]
        r, g, b = hex_to_rgb(color)
        cr = contrast_ratio(color, bg_color)

        # Create swatch using rich style
        swatch = Text("    ", style=Style(bgcolor=f"rgb({r},{g},{b})"))

        cr_color = get_contrast_color(cr)
        status = get_contrast_status(cr)

        if i == 0:
            cr_str = "---"
            status = ""
        else:
            cr_str = f"[{cr_color}]{cr:.2f}:1[/]"

        table.add_row(
            str(i),
            COLOR_NAMES_LONG[i],
            color,
            swatch,
            cr_str,
            status
        )

    return table


def create_constraint_check_table(theme: Theme) -> Table:
    """Create constraint check table like CUDA optimizer."""
    table = Table(title="Constraint Check", box=box.SIMPLE_HEAD)
    table.add_column("Constraint", width=30)
    table.add_column("Value", width=10)
    table.add_column("Status", width=10)

    bg = theme.colors[0]

    # Base colors on black
    base_ratios = [contrast_ratio(theme.colors[i], bg) for i in range(1, 7)]
    min_base = min(base_ratios)
    avg_base = sum(base_ratios) / len(base_ratios)

    min_color = get_contrast_color(min_base)
    table.add_row(
        "Base (1-6) on black min",
        f"[{min_color}]{min_base:.2f}:1[/]",
        get_contrast_status(min_base)
    )
    table.add_row(
        "Base (1-6) on black avg",
        f"{avg_base:.2f}:1",
        ""
    )

    # Individual base colors
    for i in range(1, 7):
        cr = contrast_ratio(theme.colors[i], bg)
        color = get_contrast_color(cr)
        table.add_row(
            f"  {COLOR_NAMES_LONG[i]} on black",
            f"[{color}]{cr:.2f}:1[/]",
            get_contrast_status(cr)
        )

    return table


def create_bright_on_regular_table(theme: Theme) -> Table:
    """Create bright on regular contrast table."""
    table = Table(title="Bright on Regular", box=box.SIMPLE_HEAD)
    table.add_column("Pair", width=20)
    table.add_column("Contrast", width=10)
    table.add_column("Status", width=10)

    for i in range(1, 7):
        base = theme.colors[i]
        bright = theme.colors[i + 8]
        cr = contrast_ratio(bright, base)

        color = get_contrast_color(cr)
        status = get_contrast_status(cr)

        # Create sample with actual colors
        base_r, base_g, base_b = hex_to_rgb(base)
        bright_r, bright_g, bright_b = hex_to_rgb(bright)

        pair_name = f"{COLOR_NAMES[i+8]} on {COLOR_NAMES[i]}"

        table.add_row(pair_name, f"[{color}]{cr:.2f}:1[/]", status)

    return table


def create_sample_matrix(theme: Theme, console: Console) -> str:
    """Create 16x16 sample matrix as string (for raw terminal output)."""
    lines = []
    lines.append("Sample Matrix (FG on BG)")
    lines.append("")

    # Header
    header = "FG\\BG"
    for bg in range(16):
        header += f" {bg:2d} "
    lines.append(header)

    for fg in range(16):
        row = f"  {fg:2d} "
        for bg in range(16):
            fg_r, fg_g, fg_b = hex_to_rgb(theme.colors[fg])
            bg_r, bg_g, bg_b = hex_to_rgb(theme.colors[bg])
            row += f"\033[38;2;{fg_r};{fg_g};{fg_b};48;2;{bg_r};{bg_g};{bg_b}m {fg:2d} \033[0m"
        lines.append(row)

    return "\n".join(lines)


def create_contrast_matrix_table(theme: Theme) -> Table:
    """Create contrast ratio matrix table."""
    table = Table(title="Contrast Matrix", box=box.MINIMAL, padding=0)
    table.add_column("", width=6)
    for i in range(16):
        table.add_column(str(i), width=5, justify="right")

    for fg in range(16):
        row = [COLOR_NAMES[fg][:5]]
        for bg in range(16):
            if fg == bg:
                row.append("·")
            else:
                cr = contrast_ratio(theme.colors[fg], theme.colors[bg])
                color = get_contrast_color(cr)
                row.append(f"[{color}]{cr:.1f}[/]")
        table.add_row(*row)

    return table


def create_mc_mockup(theme: Theme) -> str:
    """Generate Midnight Commander mockup."""

    def c(text: str, fg: int, bg: int) -> str:
        return f"{theme.fg(fg)}{theme.bg(bg)}{text}{RESET}"

    lines = []
    mc_width = 80
    panel_w = 39
    gap = "  "

    # Menu bar
    menu = " Left   File   Command   Options   Right "
    lines.append(c(menu.ljust(mc_width), 15, 6))

    # Panel headers
    left_title = "─ /home/user/project ─"
    right_title = "─ /home/user/output ──"
    left_header = f"┌{left_title.center(panel_w - 2, '─')}┐"
    right_header = f"┌{right_title.center(panel_w - 2, '─')}┐"
    lines.append(c(left_header, 7, 4) + gap + c(right_header, 7, 4))

    # Column headers
    col_header = " Name                    Size  MTime "
    lines.append(c(f"│{col_header}│", 3, 4) + gap + c(f"│{col_header}│", 3, 4))

    # Separator
    sep = f"├{'─' * (panel_w - 2)}┤"
    lines.append(c(sep, 7, 4) + gap + c(sep, 7, 4))

    # File entries
    left_files = [
        ("/..                   <DIR>  Jan 11", 15, 4),
        ("/src                  <DIR>  Jan 10", 15, 4),
        (" main.py               2.4K  Jan 11", 0, 6),
        (" utils.py              1.2K  Jan 10", 6, 4),
        (" config.json            512  Jan 08", 7, 4),
        (" data.tar.gz            15M  Jan 05", 13, 4),
        (" build.sh               890  Jan 04", 10, 4),
        (" README.md             3.1K  Jan 01", 7, 4),
    ]

    right_files = [
        ("/..                   <DIR>  Jan 11", 15, 4),
        ("/output               <DIR>  Jan 11", 15, 4),
        (" results.json          4.2K  Jan 11", 7, 4),
        (" log.txt               128K  Jan 11", 7, 4),
        (" backup.tar.gz          50M  Jan 10", 13, 4),
        (" run.sh                 256  Jan 09", 10, 4),
        (" notes.md              2.1K  Jan 08", 7, 4),
        ("                                    ", 7, 4),
    ]

    for (left_text, left_fg, left_bg), (right_text, right_fg, right_bg) in zip(left_files, right_files):
        left_content = left_text[:panel_w - 2].ljust(panel_w - 2)
        right_content = right_text[:panel_w - 2].ljust(panel_w - 2)
        lines.append(c(f"│{left_content}│", left_fg, left_bg) + gap + c(f"│{right_content}│", right_fg, right_bg))

    # Bottom border
    bottom = f"└{'─' * (panel_w - 2)}┘"
    lines.append(c(bottom, 7, 4) + gap + c(bottom, 7, 4))

    # Status bar
    status = " user@host:~/project$ "
    lines.append(c(status.ljust(mc_width), 0, 6))

    # Function keys
    fkeys = [("1", "Help  "), ("2", "Menu  "), ("3", "View  "), ("4", "Edit  "), ("5", "Copy  "),
             ("6", "RenMov"), ("7", "Mkdir "), ("8", "Delete"), ("9", "PullDn"), ("10", "Quit ")]
    fbar = ""
    for num, label in fkeys:
        fbar += c(num, 15, 0)
        fbar += c(label, 0, 6)
    lines.append(fbar)

    return "\n".join(lines)


def create_color_swatches(theme: Theme) -> str:
    """Create color swatch line."""
    regular = "0-7:  "
    for i in range(8):
        regular += f"{theme.bg(i)}  {i}  {RESET}"

    bright = "\n8-15: "
    for i in range(8, 16):
        bright += f"{theme.bg(i)} {i:2d}  {RESET}"

    return regular + bright


# =============================================================================
# Interactive Mode
# =============================================================================

def getch():
    """Read a single character from stdin."""
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch


def clear_screen():
    print("\033[2J\033[H", end="")


def display_theme(theme: Theme, console: Console, current: int, total: int):
    """Display theme analysis using Rich."""
    clear_screen()

    # Header
    console.print("═" * console.width)
    console.print(f"  THEME ANALYZER  │  [{current + 1}/{total}] {theme.name}")
    console.print("═" * console.width)
    console.print("  Controls: n/p/Space = next/prev │ 1-9 = select │ e = export │ q = quit")
    console.print()

    # Color swatches
    print(create_color_swatches(theme))
    print()

    # MC Mockup
    print(create_mc_mockup(theme))
    print()

    # Tables side by side would be complex - print sequentially
    console.print(create_palette_table(theme, console))
    print()

    console.print(create_constraint_check_table(theme))
    print()

    console.print(create_bright_on_regular_table(theme))
    print()

    # Sample matrix (raw terminal)
    print(create_sample_matrix(theme, console))
    print()

    console.print("─" * console.width)


def export_themes(themes_dir: Path, console: Console):
    """Export all themes to Ghostty format files."""
    console.print(f"\nExporting themes to [cyan]{themes_dir}[/]...\n")

    for theme in THEMES:
        filepath = theme.save_ghostty(themes_dir)
        console.print(f"  [green]✓[/] {theme.name} → {filepath.name}")

    console.print(f"\n[green]Exported {len(THEMES)} themes.[/]")
    console.print("To use a theme, set in ghostty config: theme = <theme-name>")


def interactive_mode():
    """Interactive theme browser."""
    console = Console()
    current = len(THEMES) - 1

    while True:
        display_theme(THEMES[current], console, current, len(THEMES))
        key = getch()

        if key == "q":
            break
        elif key == "n" or key == " ":
            current = (current + 1) % len(THEMES)
        elif key == "p":
            current = (current - 1) % len(THEMES)
        elif key.isdigit() and 1 <= int(key) <= len(THEMES):
            current = int(key) - 1
        elif key == "e":
            themes_dir = Path(__file__).parent / "themes"
            export_themes(themes_dir, console)
            print("\nPress any key to continue...")
            getch()

    clear_screen()


# =============================================================================
# Main
# =============================================================================

def main():
    console = Console()

    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "--export":
            themes_dir = Path(__file__).parent / "themes"
            export_themes(themes_dir, console)
        elif arg == "--help" or arg == "-h":
            console.print(__doc__)
        else:
            console.print(f"[red]Unknown argument:[/] {arg}")
            console.print("Use --help for usage information")
            sys.exit(1)
    else:
        interactive_mode()


if __name__ == "__main__":
    main()

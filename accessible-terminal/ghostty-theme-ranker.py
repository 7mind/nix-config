#!/usr/bin/env python3
"""
Ghostty Theme Accessibility Ranker

Analyzes all Ghostty built-in themes for WCAG contrast compliance
and ranks them by accessibility metrics.

Usage:
    python ghostty-theme-ranker.py              # Show top themes
    python ghostty-theme-ranker.py --all        # Show all themes
    python ghostty-theme-ranker.py --dark       # Only dark themes (bg luminance < 0.2)
    python ghostty-theme-ranker.py --light      # Only light themes (bg luminance > 0.5)
    python ghostty-theme-ranker.py --show NAME  # Show details for a specific theme
"""

import argparse
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Theme:
    """Parsed Ghostty theme."""
    name: str
    palette: dict[int, str] = field(default_factory=dict)
    background: str = "#000000"
    foreground: str = "#ffffff"

    def is_complete(self) -> bool:
        """Check if theme has all 16 palette colors."""
        return all(i in self.palette for i in range(16))


def hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    """Convert hex color to RGB tuple."""
    h = hex_color.lstrip("#")
    if len(h) == 3:
        h = h[0]*2 + h[1]*2 + h[2]*2
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


def parse_theme(path: Path) -> Theme | None:
    """Parse a Ghostty theme file."""
    try:
        theme = Theme(name=path.name)
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()

                if key == "palette":
                    # Format: palette = N=#xxxxxx
                    parts = value.split("=")
                    if len(parts) == 2:
                        idx = int(parts[0].strip())
                        color = parts[1].strip()
                        theme.palette[idx] = color
                elif key == "background":
                    theme.background = value
                elif key == "foreground":
                    theme.foreground = value

        return theme if theme.is_complete() else None
    except Exception as e:
        return None


@dataclass
class ThemeMetrics:
    """Accessibility metrics for a theme."""
    theme: Theme

    # Base colors (1-6) on background
    base_on_bg_min: float = 0.0
    base_on_bg_avg: float = 0.0
    base_on_bg_all_aa: bool = False  # All >= 4.5
    base_on_bg_all_ok: bool = False  # All >= 3.0

    # Bright colors (9-14) on background
    bright_on_bg_min: float = 0.0
    bright_on_bg_avg: float = 0.0

    # Foreground on background
    fg_on_bg: float = 0.0

    # Bright on regular (br.X on X)
    bright_on_regular_min: float = 0.0
    bright_on_regular_avg: float = 0.0

    # White (7) on blue (4) - common file manager pattern
    white_on_blue: float = 0.0

    # Yellow (3) on blue (4) - MC uses this
    yellow_on_blue: float = 0.0

    # Cyan (6) on blue (4) - MC cursor
    cyan_on_blue: float = 0.0

    # Overall score (higher = better)
    score: float = 0.0

    # Detailed failures
    failures: list = field(default_factory=list)

    def calculate(self):
        """Calculate all metrics."""
        bg = self.theme.background
        palette = self.theme.palette
        self.failures = []

        # Base colors on background
        base_ratios = [contrast_ratio(palette[i], bg) for i in range(1, 7)]
        self.base_on_bg_min = min(base_ratios)
        self.base_on_bg_avg = sum(base_ratios) / len(base_ratios)
        self.base_on_bg_all_aa = all(r >= 4.5 for r in base_ratios)
        self.base_on_bg_all_ok = all(r >= 3.0 for r in base_ratios)

        # Bright colors on background
        bright_ratios = [contrast_ratio(palette[i], bg) for i in range(9, 15)]
        self.bright_on_bg_min = min(bright_ratios)
        self.bright_on_bg_avg = sum(bright_ratios) / len(bright_ratios)

        # Foreground on background
        self.fg_on_bg = contrast_ratio(self.theme.foreground, bg)

        # Bright on regular
        br_on_reg = [contrast_ratio(palette[i+8], palette[i]) for i in range(1, 7)]
        self.bright_on_regular_min = min(br_on_reg)
        self.bright_on_regular_avg = sum(br_on_reg) / len(br_on_reg)

        # Important cross-color pairs (file manager patterns)
        self.white_on_blue = contrast_ratio(palette[7], palette[4])
        self.yellow_on_blue = contrast_ratio(palette[3], palette[4])
        self.cyan_on_blue = contrast_ratio(palette[6], palette[4])

        # Track failures (< 3.0)
        names = ["", "red", "green", "yellow", "blue", "magenta", "cyan"]
        for i, r in enumerate(base_ratios, 1):
            if r < 3.0:
                self.failures.append(f"{names[i]}/bg={r:.1f}")

        if self.white_on_blue < 3.0:
            self.failures.append(f"white/blue={self.white_on_blue:.1f}")
        if self.yellow_on_blue < 3.0:
            self.failures.append(f"yellow/blue={self.yellow_on_blue:.1f}")

        # Calculate overall score
        # Weight factors for different use cases
        self.score = (
            self.base_on_bg_min * 10 +      # Most important: worst base color
            self.base_on_bg_avg * 5 +        # Average base contrast
            self.bright_on_bg_min * 3 +      # Bright colors readability
            self.fg_on_bg * 2 +              # Main text readability
            self.bright_on_regular_min * 2 + # Bright on regular distinguishability
            min(self.white_on_blue, 7) * 3 + # White on blue (cap at 7)
            min(self.yellow_on_blue, 5) * 2  # Yellow on blue (cap at 5)
        )

        return self


def find_themes_dir() -> Path | None:
    """Find Ghostty themes directory."""
    # Try common locations
    candidates = [
        Path("/nix/store") / "20pmv3vfzmivwkg1bn4kv1yf1hkgh5fc-ghostty-1.2.3/share/ghostty/themes",
        Path.home() / ".config/ghostty/themes",
        Path("/usr/share/ghostty/themes"),
    ]

    # Also search nix store
    nix_store = Path("/nix/store")
    if nix_store.exists():
        for d in nix_store.iterdir():
            if "ghostty" in d.name and (d / "share/ghostty/themes").exists():
                return d / "share/ghostty/themes"

    for c in candidates:
        if c.exists():
            return c

    return None


def print_theme_details(metrics: ThemeMetrics):
    """Print detailed information about a theme."""
    theme = metrics.theme

    print(f"\n{'='*70}")
    print(f"Theme: {theme.name}")
    print(f"{'='*70}")

    print(f"\nBackground: {theme.background} (luminance: {relative_luminance(theme.background):.3f})")
    print(f"Foreground: {theme.foreground} (contrast on bg: {metrics.fg_on_bg:.2f}:1)")

    print(f"\nPalette colors on background:")
    print(f"  {'Color':<12} {'Hex':<9} {'Contrast':>8}  Status")
    print(f"  {'-'*45}")

    names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
             "br.black", "br.red", "br.green", "br.yellow", "br.blue", "br.magenta", "br.cyan", "br.white"]

    for i in range(16):
        color = theme.palette[i]
        cr = contrast_ratio(color, theme.background)
        status = "✓ AA" if cr >= 4.5 else ("~ OK" if cr >= 3.0 else "✗ LOW")

        # Color swatch using 24-bit color
        r, g, b = hex_to_rgb(color)
        swatch = f"\033[48;2;{r};{g};{b}m    \033[0m"

        print(f"  {names[i]:<12} {color:<9} {cr:>6.2f}:1  {swatch} {status}")

    print(f"\nMetrics Summary:")
    print(f"  Base colors (1-6) on bg minimum: {metrics.base_on_bg_min:.2f}:1")
    print(f"  Base colors (1-6) on bg average: {metrics.base_on_bg_avg:.2f}:1")
    print(f"  All base colors >= 4.5:1 (AA): {'Yes' if metrics.base_on_bg_all_aa else 'No'}")
    print(f"  All base colors >= 3.0:1 (OK): {'Yes' if metrics.base_on_bg_all_ok else 'No'}")
    print(f"  Bright on regular minimum: {metrics.bright_on_regular_min:.2f}:1")

    print(f"\nFile Manager Pairs (MC/ranger/etc):")
    w_status = "✓" if metrics.white_on_blue >= 4.5 else ("~" if metrics.white_on_blue >= 3.0 else "✗")
    y_status = "✓" if metrics.yellow_on_blue >= 4.5 else ("~" if metrics.yellow_on_blue >= 3.0 else "✗")
    c_status = "✓" if metrics.cyan_on_blue >= 3.0 else "✗"
    print(f"  White on blue:  {metrics.white_on_blue:>5.2f}:1  {w_status}")
    print(f"  Yellow on blue: {metrics.yellow_on_blue:>5.2f}:1  {y_status}")
    print(f"  Cyan on blue:   {metrics.cyan_on_blue:>5.2f}:1  {c_status}")

    print(f"\nOverall score: {metrics.score:.1f}")


def main():
    parser = argparse.ArgumentParser(description="Rank Ghostty themes by accessibility")
    parser.add_argument("--all", action="store_true", help="Show all themes")
    parser.add_argument("--dark", action="store_true", help="Only dark themes")
    parser.add_argument("--light", action="store_true", help="Only light themes")
    parser.add_argument("--top", type=int, default=20, help="Number of top themes to show")
    parser.add_argument("--show", type=str, help="Show details for a specific theme")
    parser.add_argument("--min-contrast", type=float, default=0, help="Filter by minimum base contrast")
    parser.add_argument("--fm", action="store_true", help="Filter for file manager compatibility (white/blue, yellow/blue >= 3.0)")
    parser.add_argument("--br", type=float, default=0, help="Minimum bright-on-regular contrast (e.g. --br 2.0)")
    parser.add_argument("--themes-dir", type=str, help="Path to themes directory")
    args = parser.parse_args()

    # Find themes directory
    if args.themes_dir:
        themes_dir = Path(args.themes_dir)
    else:
        themes_dir = find_themes_dir()

    if not themes_dir or not themes_dir.exists():
        print("Error: Could not find Ghostty themes directory", file=sys.stderr)
        print("Try: --themes-dir /path/to/ghostty/themes", file=sys.stderr)
        return 1

    print(f"Scanning themes in: {themes_dir}")

    # Parse all themes
    themes = []
    for theme_file in themes_dir.iterdir():
        if theme_file.is_file():
            theme = parse_theme(theme_file)
            if theme:
                themes.append(theme)

    print(f"Found {len(themes)} complete themes (with all 16 palette colors)")

    # Calculate metrics
    all_metrics = []
    for theme in themes:
        metrics = ThemeMetrics(theme=theme)
        metrics.calculate()
        all_metrics.append(metrics)

    # Filter by dark/light
    if args.dark:
        all_metrics = [m for m in all_metrics if relative_luminance(m.theme.background) < 0.2]
        print(f"Filtered to {len(all_metrics)} dark themes")
    elif args.light:
        all_metrics = [m for m in all_metrics if relative_luminance(m.theme.background) > 0.5]
        print(f"Filtered to {len(all_metrics)} light themes")

    # Filter by minimum contrast
    if args.min_contrast > 0:
        all_metrics = [m for m in all_metrics if m.base_on_bg_min >= args.min_contrast]
        print(f"Filtered to {len(all_metrics)} themes with min contrast >= {args.min_contrast}")

    # Filter for file manager compatibility
    if args.fm:
        all_metrics = [m for m in all_metrics if m.white_on_blue >= 3.0 and m.yellow_on_blue >= 3.0]
        print(f"Filtered to {len(all_metrics)} themes with FM compatibility (white/blue, yellow/blue >= 3.0)")

    # Filter for bright-on-regular contrast
    if args.br > 0:
        all_metrics = [m for m in all_metrics if m.bright_on_regular_min >= args.br]
        print(f"Filtered to {len(all_metrics)} themes with bright/regular >= {args.br}")

    # Show specific theme
    if args.show:
        for m in all_metrics:
            if m.theme.name.lower() == args.show.lower():
                print_theme_details(m)
                return 0
        print(f"Theme '{args.show}' not found")
        return 1

    # Sort by score (descending)
    all_metrics.sort(key=lambda m: m.score, reverse=True)

    # Display results
    print(f"\n{'Rank':<5} {'Theme':<28} {'Min':>5} {'Avg':>5} {'W/Bl':>5} {'Y/Bl':>5} {'Br/R':>5} {'Score':>5}  {'Status'}")
    print(f"{'-'*90}")

    show_count = len(all_metrics) if args.all else min(args.top, len(all_metrics))

    for i, m in enumerate(all_metrics[:show_count], 1):
        status = ""
        if m.base_on_bg_all_aa:
            status = "\033[32m✓ AA\033[0m"
        elif m.base_on_bg_all_ok:
            status = "\033[33m~ OK\033[0m"
        else:
            status = "\033[31m✗ Low\033[0m"

        # Color the white/blue and yellow/blue values
        wb = f"{m.white_on_blue:.1f}"
        if m.white_on_blue < 3.0:
            wb = f"\033[31m{wb}\033[0m"
        elif m.white_on_blue < 4.5:
            wb = f"\033[33m{wb}\033[0m"

        yb = f"{m.yellow_on_blue:.1f}"
        if m.yellow_on_blue < 3.0:
            yb = f"\033[31m{yb}\033[0m"
        elif m.yellow_on_blue < 4.5:
            yb = f"\033[33m{yb}\033[0m"

        # Color bright/regular
        br = f"{m.bright_on_regular_min:.1f}"
        if m.bright_on_regular_min < 1.5:
            br = f"\033[31m{br}\033[0m"
        elif m.bright_on_regular_min < 2.5:
            br = f"\033[33m{br}\033[0m"

        print(f"{i:<5} {m.theme.name:<28} {m.base_on_bg_min:>5.1f} {m.base_on_bg_avg:>5.1f} {wb:>5} {yb:>5} {br:>5} {m.score:>5.0f}  {status}")

    # Show summary
    aa_count = sum(1 for m in all_metrics if m.base_on_bg_all_aa)
    ok_count = sum(1 for m in all_metrics if m.base_on_bg_all_ok and not m.base_on_bg_all_aa)
    low_count = len(all_metrics) - aa_count - ok_count

    print(f"\nSummary:")
    print(f"  All colors AA (>=4.5:1): {aa_count} themes")
    print(f"  All colors OK (>=3.0:1): {ok_count} themes")
    print(f"  Some colors low (<3.0:1): {low_count} themes")

    if not args.all and show_count < len(all_metrics):
        print(f"\nShowing top {show_count} of {len(all_metrics)}. Use --all to see all.")

    return 0


if __name__ == "__main__":
    sys.exit(main())

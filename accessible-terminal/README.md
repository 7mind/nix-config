# Accessible Terminal Color Theme

A WCAG-compliant terminal color theme based on "Builtin Pastel Dark" with
improved contrast ratios for better readability in TUI applications.

## The Problem

The original "Builtin Pastel Dark" theme from Ghostty has beautiful pastel
colors, but suffers from critical accessibility issues:

1. **Low Regular/Bright Contrast**: The contrast between regular colors (0-7)
   and their bright variants (8-15) is often below 1.5:1, making them nearly
   indistinguishable.

2. **Poor TUI Readability**: Many common foreground/background combinations
   used by TUI applications like Midnight Commander, vim, and htop fall below
   the WCAG minimum contrast ratio of 3:1.

3. **Cyan/Blue Conflict**: The original cyan (#c6c5fe) is actually a light
   lavender that's nearly indistinguishable from blue backgrounds, making
   source code files in MC unreadable.

### Original Theme Problems

| Color Pair | Use Case | Original Contrast | Status |
|------------|----------|-------------------|--------|
| white on cyan | MC menu bar | ~1.1:1 | FAIL |
| black on cyan | MC selection | ~2.5:1 | FAIL |
| cyan on blue | MC source files | ~1.0:1 | FAIL |
| gray on blue | MC panel text | ~3.2:1 | OK |

## WCAG Contrast Requirements

The Web Content Accessibility Guidelines (WCAG) 2.1 define minimum contrast
ratios for text readability:

- **4.5:1** - WCAG AA for normal text
- **3.0:1** - WCAG AA for large text (18pt+ or 14pt+ bold)
- **7.0:1** - WCAG AAA for normal text

For terminal applications with monospace fonts typically rendered at 10-14pt,
we target **3.0:1 minimum** for all commonly used color combinations, with
**4.5:1** as the ideal target.

### Contrast Ratio Formula

```
contrast = (L1 + 0.05) / (L2 + 0.05)

where L1 = lighter color's relative luminance
      L2 = darker color's relative luminance
```

Relative luminance is calculated per WCAG 2.1:

```python
def relative_luminance(r, g, b):
    def linearize(c):
        c_srgb = c / 255
        if c_srgb <= 0.03928:
            return c_srgb / 12.92
        return ((c_srgb + 0.055) / 1.055) ** 2.4

    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
```

## The Challenge: Conflicting Constraints

Terminal color themes face a unique challenge: the same color index must work
in multiple contexts with different requirements.

### The Cyan Problem

Midnight Commander uses cyan (color 6) for two conflicting purposes:

1. **Menu bar background** - needs white (15) text to be readable
2. **Selection background** - needs black (0) text to be readable

For white text at 3:1 contrast, cyan needs luminance ≤ 0.21.
For black text at 3:1 contrast, cyan needs luminance ≥ 0.15.

This gives us a narrow window: **luminance between 0.15 and 0.21**.

Additionally, cyan must contrast with blue (color 4) for source file visibility
in MC panels. This requires cyan to be either:
- Much brighter than blue, OR
- A different hue (greenish teal vs pure blue)

### The Solution

After 18 iterations of testing, we found the optimal solution:

1. **Darker blue (#003068)** - Very dark for better contrast with all text
2. **Teal cyan (#009080)** - Green-shifted to differentiate from blue, with
   luminance ~0.18 to work with both white and black text
3. **Brighter gray (#a0a0a0)** - Improved visibility on blue panels
4. **Darker black (#282828)** - Better contrast in selection contexts

## Final Theme: WCAG Pastel Dark v18

```
palette = 0=#282828   # black
palette = 1=#e02818   # red
palette = 2=#30a800   # green
palette = 3=#c8a800   # yellow
palette = 4=#003068   # blue (very dark)
palette = 5=#a81098   # magenta
palette = 6=#009080   # cyan (teal)
palette = 7=#a0a0a0   # gray
palette = 8=#505050   # bright black
palette = 9=#f0a898   # bright red
palette = 10=#80d870  # bright green
palette = 11=#e8e898  # bright yellow
palette = 12=#80b0e8  # bright blue
palette = 13=#e8a0d8  # bright magenta
palette = 14=#70d8d0  # bright cyan
palette = 15=#f0f0f0  # bright white
```

### Achieved Contrast Ratios

| Color Pair | Use Case | v18 Contrast | Status |
|------------|----------|--------------|--------|
| white on cyan | MC menu bar | 3.48:1 | OK |
| black on cyan | MC selection | 3.72:1 | OK |
| cyan on blue | MC source files | 3.27:1 | OK |
| gray on blue | MC panel text | 4.95:1 | AA |
| yellow on blue | MC header | 5.58:1 | AA |
| white on red | Error dialogs | 4.11:1 | OK |
| black on gray | Dialog boxes | 5.64:1 | AA |
| white on black | Terminal default | 12.94:1 | AAA |
| br.green on black | ls executables | 8.41:1 | AAA |
| br.blue on black | ls directories | 6.52:1 | AA |

## Methodology

### 1. Analysis Phase

We analyzed all 240 possible foreground/background combinations (16×16 minus
same-color pairs) to identify problematic pairs.

### 2. Use Case Identification

We identified the most commonly used color combinations in popular TUI apps:
- Midnight Commander (file manager)
- vim/neovim (text editor)
- htop (process monitor)
- git diff output
- ls with LS_COLORS
- Error dialogs

### 3. Constraint Definition

For each use case, we defined the minimum acceptable contrast ratio and
identified any conflicting requirements.

### 4. Iterative Optimization

We created 18 theme variants, each addressing specific issues:
- v1-v6: Initial attempts at improving individual colors
- v7-v9: Shifted cyan to teal for blue background contrast
- v10-v11: Optimized for black/white on cyan
- v12-v15: Adjusted black brightness and white brightness
- v16-v17: Green-shifted cyan for better blue differentiation
- v18: Final balanced theme meeting all constraints

### 5. Visual Verification

We created mockups using 24-bit true color escape sequences to preview themes
independently of the terminal's current color scheme. This ensures accurate
representation during development.

## Usage

### Preview Tool

```bash
# Interactive mode
python theme-analyzer.py

# Show contrast analysis
python theme-analyzer.py --analyze

# Show all mockups
python theme-analyzer.py --mockups

# Show 16x16 contrast matrix
python theme-analyzer.py --matrix

# Compare themes on key metrics
python theme-analyzer.py --compare
```

### Ghostty Configuration

The theme is integrated into the NixOS configuration at
`modules/hm/ghostty.nix`. To use it:

1. Enable Ghostty in your configuration
2. The theme "WCAG Pastel Dark" will be automatically available
3. It's set as the default theme

## Trade-offs

No theme can achieve perfect contrast for all 240 color pairs. Our approach
prioritizes:

1. **Commonly used pairs** - Focus on real-world TUI applications
2. **3:1 minimum** - WCAG AA for large text as baseline
3. **Visual distinction** - Regular/bright pairs should be distinguishable
4. **Aesthetic coherence** - Maintain the "pastel dark" feel where possible

Some rarely-used pairs (like bright yellow on bright white) still have low
contrast, but these combinations are almost never used in practice.

## Files

- `theme-analyzer.py` - Interactive analysis and mockup tool
- `README.md` - This documentation
- `../modules/hm/ghostty.nix` - NixOS/home-manager integration

## References

- [WCAG 2.1 Contrast Requirements](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)
- [Relative Luminance Calculation](https://www.w3.org/WAI/GL/wiki/Relative_luminance)
- [Ghostty Terminal](https://ghostty.org/)
- [Midnight Commander](https://midnight-commander.org/)

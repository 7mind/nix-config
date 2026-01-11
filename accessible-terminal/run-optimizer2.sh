#!/usr/bin/env bash
set -euo pipefail

# Color Optimizer v2.4 - Tuned constraints
#
# Constraints:
#   1. Base colors on black with PER-COLOR minimums:
#      - Red >= 5.2 (bumped to clear 5.0)
#      - Green >= 4.5 (appear darker perceptually)
#      - Yellow, Blue, Magenta, Cyan >= 3.5
#      - All <= 7.5
#   2. Bright on regular (br.X on X): CR >= 3.0
#   3. Cyan on blue: CR >= 2.5 (relaxed)
#
# OKLCH Features:
#   - Hue spacing optimization (target: 60° between colors)
#   - Perceptual distance in Oklab space
#   - Bright colors match base hue
#   - Chroma (saturation) bonus
#
# Fixed colors:
#   - Black: #000000
#   - White: #bfbfbf
#   - Br.Black: #404040
#   - Br.White: #ffffff

cd "$(dirname "$0")"

# Default parameters
GENERATIONS=${1:-5000}
POPULATION=${2:-200000}

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                   Color Optimizer v2.5 Launcher                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo
echo "Parameters: generations=$GENERATIONS, population=$POPULATION"
echo

# Theme output file (optional)
THEME_FILE="${3:-}"
OUTPUT_ARG=""
if [ -n "$THEME_FILE" ]; then
    OUTPUT_ARG="-o $THEME_FILE"
    echo "Output theme file: $THEME_FILE"
fi
echo

# Ensure LD_LIBRARY_PATH includes OpenGL driver
export LD_LIBRARY_PATH=/run/opengl-driver/lib:${LD_LIBRARY_PATH:-}

# Run inside nix develop environment
nix develop -c bash -c "
  echo 'Compiling...'
  nvcc -O3 -Wno-deprecated-gpu-targets -o color-optimizer2 color-optimizer2.cu -lcurand && \
  echo 'Running optimizer...' && \
  echo && \
  ./color-optimizer2 -g $GENERATIONS -p $POPULATION $OUTPUT_ARG
"

if [ -n "$THEME_FILE" ]; then
    echo
    echo "Theme written to: $THEME_FILE"
    echo "To use: theme = $(basename "$THEME_FILE")"
fi

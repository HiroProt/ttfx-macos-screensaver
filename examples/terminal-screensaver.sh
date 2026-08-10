#!/bin/sh
# The same idea in a terminal instead of a screensaver: random effect on a
# logo, forever, centered on a canvas that fills the window. Fullscreen your
# terminal first. Needs the ttfx binary — https://github.com/omacom-io/ttfx
#
#   TTFX=/path/to/ttfx examples/terminal-screensaver.sh [logo.txt]
#
# This mirrors Omarchy's bin/omarchy-cmd-screensaver, which runs:
#   tte -i screensaver.txt --frame-rate 120 --canvas-width 0 --canvas-height 0 \
#       --anchor-canvas c --anchor-text c --random-effect
# with the logo overridable at ~/.config/omarchy/branding/screensaver.txt.
# Ctrl-C exits: ttfx restores the cursor and returns 1, ending the loop.
set -e

here=$(cd "$(dirname "$0")" && pwd)
bin="${TTFX:?set TTFX to the path of a ttfx binary}"
logo="${1:-$here/logos/ttfx.txt}"

while "$bin" -i "$logo" \
  --frame-rate 120 --canvas-width 0 --canvas-height 0 \
  --anchor-canvas c --anchor-text c \
  --random-effect
do :; done

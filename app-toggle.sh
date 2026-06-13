#!/usr/bin/env bash
# app-toggle.sh — launch an app, or toggle its window if it's already running.
# For X11 desktops (Cinnamon, XFCE, MATE, etc.). Needs: xdotool, wmctrl.
#
# Bind a macro_keyboard macro key to a unique hotkey (e.g. F13), then bind that
# hotkey in your desktop to:  app-toggle.sh <window-class> <launch-command>
#
# Behaviour:
#   - app not running        -> launch it
#   - running but not focused -> raise + focus it (un-hide)
#   - running and focused     -> minimise it (hide)
#
# Examples:
#   app-toggle.sh firefox       firefox
#   app-toggle.sh code          code
#   app-toggle.sh org.gnome.Terminal  gnome-terminal

set -euo pipefail

class="${1:?usage: app-toggle.sh <window-class> <launch-command...>}"
shift
launch=("$@")

# Find a window whose WM_CLASS matches (case-insensitive).
win="$(xdotool search --classname --class "(?i)$class" 2>/dev/null | head -n1 || true)"

if [[ -z "$win" ]]; then
	# Not running: launch it.
	if [[ ${#launch[@]} -eq 0 ]]; then
		echo "no window for '$class' and no launch command given" >&2
		exit 1
	fi
	exec "${launch[@]}"
fi

active="$(xdotool getactivewindow 2>/dev/null || echo 0)"

if [[ "$win" == "$active" ]]; then
	# Focused -> hide it.
	xdotool windowminimize "$win"
else
	# Running but not focused -> raise + focus it.
	wmctrl -i -a "$win"
fi

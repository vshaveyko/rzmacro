#!/bin/zsh
# Stops RZMacro and removes the installed app. Your config (~/.config/rzmacro) is left alone.
# If "Start RZMacro when I log in" is on, turn it off in the app first (Settings > Startup),
# or remove it afterwards in System Settings > General > Login Items.
set -uo pipefail

app="$HOME/Applications/RZMacro.app"

# Take the hero-detection settings file back out of Dota 2, if it was set up.
"$app/Contents/MacOS/rzmacro" dota remove >/dev/null 2>&1
# `quit` first so the devices are switched back to normal mode cleanly.
"$app/Contents/MacOS/rzmacro" quit >/dev/null 2>&1
rm -f "$HOME/.local/bin/rzmacro"
rm -rf "$app"
echo "removed. Config kept at ~/.config/rzmacro; permissions can be removed in System Settings > Privacy & Security."

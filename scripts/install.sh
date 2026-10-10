#!/bin/zsh
# Builds RZMacro, puts it in ~/Applications and opens it.
# Starting at login is a switch in the app (Settings > Startup), not something this script decides.
set -euo pipefail
cd "${0:A:h}/.."

app="$HOME/Applications/RZMacro.app"

./scripts/build.sh

# Stop a running copy, from here or from a previous install, so the devices are handed over cleanly.
build/RZMacro.app/Contents/MacOS/rzmacro quit >/dev/null 2>&1 || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$app"
cp -R build/RZMacro.app "$app"

if [[ -d "$HOME/.local/bin" ]]; then
    ln -sf "$app/Contents/MacOS/rzmacro" "$HOME/.local/bin/rzmacro"
fi

open "$app"
echo "installed $app"

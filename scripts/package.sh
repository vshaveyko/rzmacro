#!/bin/zsh
# Builds a distributable dist/RZMacro-<version>.zip.
#
# The app in it is ad-hoc signed: it carries nobody's identity, which also means macOS treats
# every release as a new app (permissions are granted per release) and Gatekeeper has to be told
# to open it the first time. Building from source with your own signing identity avoids both.
set -euo pipefail
cd "${0:A:h}/.."

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
RZMACRO_SIGN_IDENTITY=- ./scripts/build.sh

mkdir -p dist
zip="dist/RZMacro-$version.zip"
rm -f "$zip"
ditto -c -k --norsrc --noextattr --keepParent build/RZMacro.app "$zip"
echo "packaged $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"

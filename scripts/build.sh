#!/bin/zsh
# Builds build/RZMacro.app and signs it.
#
# macOS ties the Input Monitoring / Accessibility grants to the code signature. Signing with a
# real identity keeps them across rebuilds; with ad-hoc signing ("-") they must be re-granted
# after every build. Override the identity with RZMACRO_SIGN_IDENTITY.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

identity="${RZMACRO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
identity="${identity:--}"

app=build/RZMacro.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/rzmacro "$app/Contents/MacOS/rzmacro"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign "$identity" --identifier dev.vadimsh.rzmacro "$app"

echo "built $app (signed: $identity)"

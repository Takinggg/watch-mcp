#!/usr/bin/env bash
# Builds companion/build/WatchRecorder.app (release, ad-hoc signed, for local use).
# Distribution to other Macs needs a Developer ID signature and notarization: see README.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/WatchRecorder.app"
swift build -c release --package-path "$HERE"
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/WatchRecorder"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WatchRecorder"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Signing identity, in this order:
#   1. WATCHRECORDER_SIGN_IDENTITY (any code-signing certificate in your keychains);
#   2. the local identity made by make-signing-identity.sh, once trusted for code signing (README);
#   3. ad-hoc. With ad-hoc signing every rebuild is a new app for macOS, so the Screen Recording,
#      Microphone and Accessibility permissions must be granted again after each rebuild.
ID=io.github.takinggg.watchrecorder
KEYCHAIN="$HERE/.signing/watchrecorder.keychain-db"

# codesign only reads keychains on the user's search list: list the project keychain while
# signing, then put the list back exactly as it was (also on failure).
sign_with_local_identity() {
  local original=()
  while IFS= read -r line; do original+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)
  trap 'security list-keychains -d user -s "${original[@]}"' RETURN
  security list-keychains -d user -s "${original[@]}" "$KEYCHAIN"
  security unlock-keychain -p "$(cat "$HERE/.signing/keychain-password")" "$KEYCHAIN"
  codesign --force --sign "WatchRecorder Local Signing" --keychain "$KEYCHAIN" --identifier "$ID" "$APP"
}

if [ -n "${WATCHRECORDER_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$WATCHRECORDER_SIGN_IDENTITY" --identifier "$ID" "$APP"
elif [ -f "$KEYCHAIN" ] && sign_with_local_identity 2>/dev/null; then
  echo "Signed with the local identity (permissions survive rebuilds)."
else
  [ -f "$KEYCHAIN" ] && echo "warning: could not sign with the local identity (not trusted for code signing yet? see README); signing ad-hoc." >&2
  codesign --force --sign - --identifier "$ID" "$APP"
fi
codesign --verify --verbose=1 "$APP"
echo "$APP"

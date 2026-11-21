#!/bin/zsh
# Build a Release IPA for testers to sideload (AltStore, SideStore, Sideloadly, …): the app and its
# two extensions, ad-hoc signed with their entitlements so the sideloader re-signs them with the
# tester's own Apple ID and remaps the shared app group. No Apple Developer account is needed here.
#   scripts/make-ipa.sh            → build/BitChord-<version>.ipa
# JOBS=n caps parallel compile jobs (default 3), as in the other scripts.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

python3 scripts/apply-korean.py
MIN_IOS=17.0 SDK_NAME=iphoneos bash WireGuard/build-ios.sh

DERIVED=.derived-release

# ONNX Runtime (Automix's beat/vocal models) comes from a Swift package on GitHub. If that source
# cannot be reached, build without it instead of failing: Automix keeps its DSP analysis.
#   BITCHORD_ONNX=on|off|auto (default auto)   BITCHORD_ONNX_URL=<mirror or fork of the package>
export BITCHORD_ONNX_URL=${BITCHORD_ONNX_URL:-https://github.com/microsoft/onnxruntime-swift-package-manager}
resolve_packages() {
  xcodebuild -resolvePackageDependencies -workspace BitChord.xcworkspace -scheme BitChord \
    -derivedDataPath "$DERIVED" -quiet
}
if [ "${BITCHORD_ONNX:-auto}" = auto ]; then
  export BITCHORD_ONNX=off
  for attempt in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 git ls-remote --tags "$BITCHORD_ONNX_URL" refs/tags/1.24.2 2>/dev/null | grep -q 'refs/tags/1.24.2'; then
      export BITCHORD_ONNX=on; break
    fi
    echo "ONNX Runtime package source unreachable (attempt $attempt of 3)" >&2
    sleep $((attempt * 5))
  done
fi
if [ "$BITCHORD_ONNX" = on ]; then
  resolved=0
  for attempt in 1 2 3; do
    if resolve_packages; then resolved=1; break; fi
    echo "Package resolution failed (attempt $attempt of 3)" >&2
    sleep $((attempt * 10))
  done
  if [ "$resolved" = 0 ]; then export BITCHORD_ONNX=off; fi
fi
if [ "$BITCHORD_ONNX" = off ]; then
  echo "::warning::Building WITHOUT ONNX Runtime; Automix uses its DSP estimate only"
  echo "Building without ONNX Runtime (BITCHORD_ONNX=off)" >&2
fi
echo "ONNX Runtime: $BITCHORD_ONNX ($BITCHORD_ONNX_URL)"

xcodebuild build -workspace BitChord.xcworkspace -scheme BitChord -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" -jobs "${JOBS:-3}" -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

APP="$DERIVED/Build/Products/Release-iphoneos/BitChord.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
STAGED="$STAGE/Payload/BitChord.app"

# Keep only English and Korean resources in the packaged app.
bash scripts/strip-language-packs.sh "$STAGED"

# A prior build-for-testing can leave a test bundle in the shared product directory.
# It must never ship in a sideload IPA, even when a normal build did not clean it up.
find "$STAGED" -type d -name '*.xctest' -prune -exec rm -rf {} \;

# Inside out: embedded frameworks, then each extension with its entitlements, then the app.
find "$STAGED" -name "*.framework" -type d -prune | while read -r fw; do
  codesign --force --sign - --timestamp=none "$fw"
done
codesign --force --sign - --timestamp=none --entitlements App/Config/BitChordWidget.entitlements \
  "$STAGED/PlugIns/BitChordWidgetExtension.appex"
codesign --force --sign - --timestamp=none --entitlements App/Config/BitChordShare.entitlements \
  "$STAGED/PlugIns/BitChordShareExtension.appex"
codesign --force --sign - --timestamp=none --entitlements App/Config/BitChord.entitlements "$STAGED"

mkdir -p build
OUT="build/BitChord-$VERSION.ipa"
rm -f "$OUT"
(cd "$STAGE" && zip -qry - Payload) > "$OUT"
echo "$OUT ($(du -h "$OUT" | cut -f1))"
scripts/verify-ipa.sh "$OUT"

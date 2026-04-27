#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-debug}"
APP_NAME="Echo"
APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH" "$CONTENTS/MacOS/$APP_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Copy SPM-generated resource bundles (Silero ONNX model lives in Echo_Echo.bundle).
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$CONTENTS/Resources/"
done

# Ad-hoc sign so TCC can attribute the mic permission grant.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "built $APP_DIR"
echo "run:    open $APP_DIR"
echo "logs:   log stream --predicate 'process == \"$APP_NAME\"'"

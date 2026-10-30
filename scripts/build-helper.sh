#!/bin/sh
# Builds helper/Agent Peek.app around a universal (Apple Silicon + Intel) peek-helper binary.
# The server launches the app through LaunchServices, so macOS grants permissions to Agent Peek itself.
set -eu
cd "$(dirname "$0")/.."

# Prefer the Command Line Tools when Xcode is installed but its license isn't accepted.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find swiftc >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

version=$(node -p 'require("./package.json").version')
app="helper/Agent Peek.app"
bin="$app/Contents/MacOS/peek-helper"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" helper/peek-helper.swift -o "$tmp/peek-helper-$arch"
done

rm -rf "$app" helper/peek-helper
mkdir -p "$app/Contents/MacOS"
lipo -create "$tmp/peek-helper-arm64" "$tmp/peek-helper-x86_64" -output "$bin"
# LSUIElement keeps it out of the Dock; each launch runs one command and exits.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.lu-wo.agent-peek</string>
  <key>CFBundleName</key><string>Agent Peek</string>
  <key>CFBundleDisplayName</key><string>Agent Peek</string>
  <key>CFBundleExecutable</key><string>peek-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# With a Developer ID (PEEK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)") the app gets the hardened
# runtime and a secure timestamp, which notarization requires, and macOS keeps its permissions across updates.
# Ad-hoc signed builds lose their permissions whenever the binary changes.
if [ -n "${PEEK_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$PEEK_SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
echo "built $app ($(lipo -archs "$bin"), signed: ${PEEK_SIGN_IDENTITY:-ad-hoc})"

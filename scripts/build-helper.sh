#!/bin/sh
# Builds helper/peek-helper as a universal (Apple Silicon + Intel) binary.
set -eu
cd "$(dirname "$0")/.."

# Prefer the Command Line Tools when Xcode is installed but its license isn't accepted.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find swiftc >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

out=helper/peek-helper
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" helper/peek-helper.swift -o "$tmp/peek-helper-$arch"
done
lipo -create "$tmp/peek-helper-arm64" "$tmp/peek-helper-x86_64" -output "$out"
# With a Developer ID (PEEK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)") the binary
# gets the hardened runtime and a secure timestamp, which notarization requires. Otherwise ad-hoc.
if [ -n "${PEEK_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$PEEK_SIGN_IDENTITY" "$out"
else
  codesign --force --sign - "$out"
fi
echo "built $out ($(lipo -archs "$out"), signed: ${PEEK_SIGN_IDENTITY:-ad-hoc})"

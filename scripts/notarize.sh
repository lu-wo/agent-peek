#!/bin/sh
# Submits a Developer ID-signed binary to Apple's notary service and waits for the verdict.
# Credentials, either:
#   PEEK_NOTARY_PROFILE   a keychain profile saved with `xcrun notarytool store-credentials`
#   APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER   an App Store Connect API key (CI)
# A bare binary can't be stapled; Gatekeeper looks the ticket up online on first run.
set -eu
bin=${1:?usage: notarize.sh <signed binary>}

if [ -n "${PEEK_NOTARY_PROFILE:-}" ]; then
  auth="--keychain-profile $PEEK_NOTARY_PROFILE"
elif [ -n "${APPLE_API_KEY_PATH:-}" ]; then
  auth="--key $APPLE_API_KEY_PATH --key-id ${APPLE_API_KEY_ID:?} --issuer ${APPLE_API_ISSUER:?}"
else
  echo "notarize.sh: set PEEK_NOTARY_PROFILE or APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ditto -c -k --keepParent "$bin" "$tmp/submission.zip"
# shellcheck disable=SC2086
xcrun notarytool submit "$tmp/submission.zip" $auth --wait --output-format json > "$tmp/result.json"
status=$(node -p 'require(process.argv[1]).status' "$tmp/result.json")
if [ "$status" != "Accepted" ]; then
  id=$(node -p 'require(process.argv[1]).id' "$tmp/result.json")
  echo "notarization $status; details:" >&2
  # shellcheck disable=SC2086
  xcrun notarytool log "$id" $auth >&2 || true
  exit 1
fi
echo "notarized $bin"

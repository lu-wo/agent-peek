#!/bin/sh
# Builds the release artifacts in dist/:
#   agent-peek.mcpb             one-click Claude desktop extension
#   agent-peek-macos.tar.gz     machine-wide install (used by install.sh)
set -eu
cd "$(dirname "$0")/.."

version=$(node -p 'require("./package.json").version')
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync("manifest.json", "utf8"));
  if (m.version !== process.argv[1]) throw new Error(`manifest.json version ${m.version} != package.json ${process.argv[1]}`);
' "$version"

if [ -n "${PEEK_SIGN_IDENTITY:-}" ]; then
  scripts/build-helper.sh
  scripts/notarize.sh helper/peek-helper
else
  [ -x helper/peek-helper ] || scripts/build-helper.sh
fi

rm -rf dist
stage=dist/agent-peek
mkdir -p "$stage/helper"
cp manifest.json package.json package-lock.json server.mjs cli.mjs README.md LICENSE "$stage/"
cp helper/peek-helper "$stage/helper/"
(cd "$stage" && npm ci --omit=dev --ignore-scripts --silent)

npx -y @anthropic-ai/mcpb pack "$stage" dist/agent-peek.mcpb >/dev/null
tar -czf dist/agent-peek-macos.tar.gz -C dist agent-peek
(cd dist && shasum -a 256 agent-peek.mcpb agent-peek-macos.tar.gz > SHA256SUMS)
echo "agent-peek $version"
ls -lh dist | tail -n +2

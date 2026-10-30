#!/bin/sh
# agent-peek installer: installs peek once on this Mac and connects it to every agent found.
#   curl -fsSL https://raw.githubusercontent.com/lu-wo/agent-peek/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --no-messages           # leave out Messages history
#   curl -fsSL .../install.sh | sh -s -- codex claude-desktop    # only these agents
set -eu

REPO="lu-wo/agent-peek"
DEST="${AGENT_PEEK_HOME:-$HOME/.agent-peek}"
BASE="${AGENT_PEEK_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "agent-peek only runs on macOS."

# GUI agent apps don't load your shell profile, so record an absolute path to node.
NODE=""
for candidate in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then NODE="$candidate"; break; fi
done
[ -n "$NODE" ] || die "Node.js 18 or newer is required (https://nodejs.org or: brew install node).
Only using the Claude desktop app? Download agent-peek.mcpb from https://github.com/$REPO/releases instead."
"$NODE" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' || die "Node.js 18 or newer is required (found $("$NODE" --version))."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Downloading agent-peek…"
curl -fsSL "$BASE/agent-peek-macos.tar.gz" -o "$tmp/agent-peek-macos.tar.gz"
curl -fsSL "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep ' agent-peek-macos.tar.gz$' SHA256SUMS | shasum -a 256 -c - >/dev/null) || die "checksum mismatch; download again."
tar -xzf "$tmp/agent-peek-macos.tar.gz" -C "$tmp"

rm -rf "$DEST.new"
mv "$tmp/agent-peek" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
say "Installed to $DEST ($("$NODE" -p "require('$DEST/package.json').version"))"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/agent-peek" <<SH
#!/bin/sh
exec "$NODE" "$DEST/cli.mjs" "\$@"
SH
chmod +x "$HOME/.local/bin/agent-peek"

say ""
"$NODE" "$DEST/cli.mjs" connect "$@"
say ""
case ":$PATH:" in
  *":$HOME/.local/bin:"*) say "Run \`agent-peek doctor\` any time to check permissions." ;;
  *) say "Run \`$HOME/.local/bin/agent-peek doctor\` to check permissions (add ~/.local/bin to your PATH to shorten it)." ;;
esac

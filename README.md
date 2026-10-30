# agent-peek

**Let your AI agents see what you're looking at on your Mac.**

Connectors cover Notion, Slack and Gmail. They don't cover the PDF open in Preview, the page in your browser, the chart in some internal tool, or the conversation in Messages. Peek gives your local agents (the Claude desktop app, Claude Code and Codex) a read-only view of anything open on your Mac. The agent decides what it needs, and you decide what's off limits.

```
You:    Summarize the PDF I have open in Preview.
Claude: → list_sources   (sees Preview, Arc, Slack, Notes…)
        → peek(Preview)
        "It's a 12-page lease. The key terms are…"
```

## What it can read

| Source | How |
|---|---|
| Any app window: visible, minimized, or on another Space | macOS Accessibility gives the text, including text scrolled out of view where the app exposes it. Windows on other Spaces are read with Apple's built-in OCR on a screenshot. |
| Screenshots of any window | One window at a time, never your whole screen |
| Arc and Chrome tabs, including background tabs | The live page through the browser, or a logged-out fetch of the URL |
| PDFs and documents open in Preview, TextEdit and similar apps | The whole file, not just the visible page |
| Clipboard | Text, links, copied files, images |
| Files selected in Finder | PDF, Word, RTF, HTML, text and code files, images, folders |
| iMessage / SMS history *(on by default, can be turned off)* | The local Messages database, with contact names |

Tested with Arc, Chrome, Slack, Notion, Linear, Granola, Messages, Spotify and Docker Desktop. Electron and Chromium apps are supported: peek turns on their accessibility tree for you.

## Install

Pick one of the two modes.

### A. For one agent

**Claude desktop app:** download [`agent-peek.mcpb`](https://github.com/lu-wo/agent-peek/releases/latest/download/agent-peek.mcpb), double-click it, and click **Install**. Settings → Extensions → Peek lets you turn off Messages and block apps.

**Claude Code** or **Codex**: use the machine-wide installer below and name just that agent:

```sh
curl -fsSL https://raw.githubusercontent.com/lu-wo/agent-peek/main/install.sh | sh -s -- claude-code
```

### B. Machine-wide, connected to every agent

```sh
curl -fsSL https://raw.githubusercontent.com/lu-wo/agent-peek/main/install.sh | sh
```

This installs peek once to `~/.agent-peek` and connects it to every supported agent it finds: the Claude desktop app, Claude Code and Codex. Add `--no-messages` to leave out Messages history, or `--block "Signal,WhatsApp"` to block apps:

```sh
curl -fsSL https://raw.githubusercontent.com/lu-wo/agent-peek/main/install.sh | sh -s -- --no-messages --block "Signal"
```

Manage it later with the `agent-peek` command:

```sh
agent-peek connect codex          # connect another agent
agent-peek disconnect claude-desktop
agent-peek doctor                 # check connections and permissions
agent-peek doctor --open-settings # open the right System Settings panes
```

Before changing an agent's config file, peek saves a one-time backup next to it (`*.peek-backup`). It never touches anything else in that file.

The machine-wide install needs Node.js 18 or newer (`brew install node`). The Claude extension doesn't, because Claude ships its own Node.js.

### Then grant permissions (both modes)

macOS gives permissions to **the app that runs peek**: Claude.app, Codex.app, or your terminal for the CLIs. Open System Settings → Privacy & Security and turn that app on under:

- **Accessibility**: reading window text
- **Screen Recording**: screenshots, and windows on other Spaces
- **Full Disk Access**: Messages history (skip it if you turned Messages off)

Then restart the app. The first time peek reads a browser tab, macOS asks whether the app may control Arc or Chrome. Click Allow.

> **"peek-helper Not Opened" / "Apple could not verify…"** Peek isn't notarized yet. Open System Settings → Privacy & Security, scroll to *Security*, click **Allow Anyway** next to peek-helper, and retry. The `curl` installer avoids this prompt.

The ChatGPT chat app isn't supported because it only accepts remote servers. Codex inside the ChatGPT desktop app works.

## Tools

| Tool | What it does |
|---|---|
| `list_sources` | Lists windows front to back, each with a state (`visible`, `minimized`, `hidden`, `otherSpace`), plus every Arc and Chrome tab. Reads no content. |
| `peek(id, screenshot?, max_chars?)` | Returns a window's text, URL and open document, and optionally a screenshot |
| `read_tab(url, activate?, max_chars?)` | Returns any tab's text. `activate: true` switches to a suspended tab for about 1.5 seconds to read the logged-in page, then switches back. |
| `peek_clipboard` | Returns the clipboard contents |
| `peek_finder_selection` | Returns the selected Finder files with their contents |
| `messages_list_chats` / `messages_read` / `messages_search` | Read Messages history (unless turned off) |

## Privacy

- **Read-only.** Peek never clicks, types or sends. The only visible effect is `read_tab` with `activate: true`, which switches a tab and switches it back.
- **Local.** Peek makes no network calls, with one exception: fetching a public URL when a background tab is suspended. What an agent reads goes to that agent's model provider, just like anything else you share with it.
- **You set the limits.** Password managers (Passwords, 1Password, Bitwarden, Keychain Access) are always blocked. Block more with `--block` or in the Claude extension's settings. Messages can be turned off with `--no-messages` or in the extension settings; without Full Disk Access it can't read anything anyway.
- **Prompt injection.** Window and web content can contain text written to manipulate an agent. Peek labels everything it returns as untrusted data, and the agent should never follow instructions found in it.

## Limitations

- macOS 13 or newer.
- Apps running with no window open can't be read; Messages history is the exception. Hidden apps (⌘H) are listed but usually can't be read.
- Long lists like Slack channels and Messages threads only expose the rows currently rendered. Scroll to load more, or enable Messages history.
- Apps that draw their own UI (canvases, games) expose little text. Use `screenshot: true`.
- OCR text, used for other Spaces, has no links or structure.
- The machine-wide install records the absolute path to `node`. If you switch Node versions (nvm, for example), run `agent-peek connect` again.

## How it works

- `helper/peek-helper.swift` is a small native CLI using CoreGraphics (window list), Accessibility (text), `screencapture` (screenshots), Vision (OCR), PDFKit (PDFs), NSPasteboard (clipboard) and SQLite (Messages and Contacts).
- `server.mjs` is an MCP server on stdio. It calls the helper, AppleScript (browser tabs, Finder selection) and `textutil` for Word, RTF and HTML.
- `cli.mjs` provides the `agent-peek` connect, disconnect and doctor commands.

## Develop

```sh
npm install
scripts/build-helper.sh    # universal helper binary
scripts/package.sh         # dist/agent-peek.mcpb + dist/agent-peek-macos.tar.gz
node cli.mjs connect claude-code
```

Releases are built by GitHub Actions when a `v*` tag is pushed.

## License

MIT

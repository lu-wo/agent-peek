#!/usr/bin/env node
// agent-peek CLI: run the MCP server, connect it to agents, and check permissions.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = join(HERE, "server.mjs");
const HELPER = join(HERE, "helper", "peek-helper");
const HOME = homedir();

const AGENTS = {
  "claude-desktop": {
    name: "Claude desktop app",
    app: "Claude.app",
    config: join(HOME, "Library/Application Support/Claude/claude_desktop_config.json"),
    detect: () => existsSync("/Applications/Claude.app"),
  },
  "claude-code": {
    name: "Claude Code (CLI)",
    app: "your terminal app",
    detect: async () => Boolean(await which("claude")),
  },
  codex: {
    name: "Codex (app and CLI)",
    app: "Codex.app or your terminal app",
    config: join(HOME, ".codex/config.toml"),
    detect: async () => existsSync(join(HOME, ".codex")) || existsSync("/Applications/Codex.app") || Boolean(await which("codex")),
  },
};

const SETTINGS = {
  accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
  screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
  fullDisk: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
};

async function which(cmd) {
  return run("/bin/zsh", ["-lc", `command -v ${cmd}`]).then((r) => r.stdout.trim()).catch(() => "");
}

function parseFlags(argv) {
  const flags = { messages: true, block: "", agents: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--no-messages") flags.messages = false;
    else if (a === "--messages") flags.messages = true;
    else if (a === "--block") flags.block = argv[++i] ?? "";
    else if (a.startsWith("--block=")) flags.block = a.slice(8);
    else if (a === "--open-settings") flags.openSettings = true;
    else flags.agents.push(a);
  }
  return flags;
}

function serverEnv(flags) {
  const env = {};
  if (!flags.messages) env.PEEK_MESSAGES = "0";
  if (flags.block) env.PEEK_BLOCK = flags.block;
  return env;
}

async function resolveAgents(names) {
  if (names.length && !names.includes("all")) {
    for (const n of names) if (!AGENTS[n]) throw new Error(`Unknown agent "${n}". Use one of: ${Object.keys(AGENTS).join(", ")}, all`);
    return names;
  }
  const found = [];
  for (const [key, a] of Object.entries(AGENTS)) if (await a.detect()) found.push(key);
  return found;
}

async function backup(path) {
  if (existsSync(path) && !existsSync(`${path}.peek-backup`)) await copyFile(path, `${path}.peek-backup`);
}

// MARK: - Per-agent config writers

async function readJSON(path) {
  return existsSync(path) ? JSON.parse(await readFile(path, "utf8")) : {};
}

const claudeDesktop = {
  async connect(env) {
    const path = AGENTS["claude-desktop"].config;
    const cfg = await readJSON(path);
    await backup(path);
    cfg.mcpServers = { ...cfg.mcpServers, peek: { command: process.execPath, args: [SERVER], env } };
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `${JSON.stringify(cfg, null, 2)}\n`);
  },
  async disconnect() {
    const path = AGENTS["claude-desktop"].config;
    const cfg = await readJSON(path);
    if (!cfg.mcpServers?.peek) return false;
    await backup(path);
    delete cfg.mcpServers.peek;
    await writeFile(path, `${JSON.stringify(cfg, null, 2)}\n`);
    return true;
  },
  async connected() {
    return Boolean((await readJSON(AGENTS["claude-desktop"].config)).mcpServers?.peek);
  },
};

const claudeCode = {
  async connect(env) {
    await run("claude", ["mcp", "remove", "peek", "-s", "user"]).catch(() => {});
    const envArgs = Object.entries(env).flatMap(([k, v]) => ["-e", `${k}=${v}`]);
    await run("claude", ["mcp", "add", "peek", "-s", "user", ...envArgs, "--", process.execPath, SERVER]);
  },
  async disconnect() {
    return run("claude", ["mcp", "remove", "peek", "-s", "user"]).then(() => true).catch(() => false);
  },
  async connected() {
    return run("claude", ["mcp", "get", "peek"]).then(() => true).catch(() => false);
  },
};

const tomlString = (s) => JSON.stringify(s);

// Removes [mcp_servers.peek] and its subtables, leaving every other line untouched.
function withoutPeekTable(toml) {
  const out = [];
  let skipping = false;
  for (const line of toml.split("\n")) {
    const header = line.match(/^\s*\[\[?([^\]]+)\]\]?\s*$/);
    if (header) skipping = /^mcp_servers\.peek(\.|$)/.test(header[1].trim());
    if (!skipping) out.push(line);
  }
  return out.join("\n").replace(/\n{3,}$/, "\n\n");
}

const codex = {
  async connect(env) {
    const path = AGENTS.codex.config;
    const current = existsSync(path) ? await readFile(path, "utf8") : "";
    await backup(path);
    const envLine = Object.keys(env).length
      ? `env = { ${Object.entries(env).map(([k, v]) => `${k} = ${tomlString(v)}`).join(", ")} }\n`
      : "";
    const table = `[mcp_servers.peek]\ncommand = ${tomlString(process.execPath)}\nargs = [${tomlString(SERVER)}]\n${envLine}`;
    const base = withoutPeekTable(current).trimEnd();
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `${base ? `${base}\n\n` : ""}${table}`);
  },
  async disconnect() {
    const path = AGENTS.codex.config;
    if (!existsSync(path)) return false;
    const current = await readFile(path, "utf8");
    const next = withoutPeekTable(current);
    if (next === current) return false;
    await backup(path);
    await writeFile(path, `${next.trimEnd()}\n`);
    return true;
  },
  async connected() {
    return existsSync(AGENTS.codex.config) && /^\s*\[mcp_servers\.peek\]/m.test(await readFile(AGENTS.codex.config, "utf8"));
  },
};

const WRITERS = { "claude-desktop": claudeDesktop, "claude-code": claudeCode, codex };

// MARK: - Commands

async function connect(flags) {
  const agents = await resolveAgents(flags.agents);
  if (!agents.length) {
    console.log("No supported agents found. Install the Claude desktop app, Claude Code or Codex, or name one explicitly.");
    return;
  }
  for (const key of agents) {
    try {
      await WRITERS[key].connect(serverEnv(flags));
      console.log(`✓ ${AGENTS[key].name}: connected`);
    } catch (e) {
      console.log(`✗ ${AGENTS[key].name}: ${e.message.split("\n")[0]}`);
    }
  }
  console.log(`\nMessages history: ${flags.messages ? "on (needs Full Disk Access; reconnect with --no-messages to turn off)" : "off"}`);
  console.log("\nNext: restart each agent app, then grant it permissions. Run `agent-peek doctor` for details.");
}

async function disconnect(flags) {
  const agents = flags.agents.length ? await resolveAgents(flags.agents) : Object.keys(AGENTS);
  for (const key of agents) {
    const removed = await WRITERS[key].disconnect().catch(() => false);
    console.log(`${removed ? "✓" : "–"} ${AGENTS[key].name}: ${removed ? "disconnected" : "was not connected"}`);
  }
}

async function doctor(flags) {
  console.log(`agent-peek at ${HERE}\nnode ${process.version} (${process.execPath})\n`);
  let probe;
  try {
    probe = JSON.parse((await run(HELPER, ["list"])).stdout);
    console.log("✓ helper runs");
  } catch (e) {
    console.log(`✗ helper failed: ${e.message.split("\n")[0]}`);
  }
  if (probe) {
    console.log(`  From this terminal: Accessibility ${probe.accessibilityTrusted ? "✓" : "✗"}  Screen Recording ${probe.screenRecording ? "✓" : "✗"}`);
  }

  console.log("\nAgents:");
  for (const [key, a] of Object.entries(AGENTS)) {
    const installed = await a.detect();
    const connected = installed && (await WRITERS[key].connected().catch(() => false));
    console.log(`  ${connected ? "✓" : installed ? "○" : "–"} ${a.name}: ${connected ? `connected, grant permissions to ${a.app}` : installed ? "installed, not connected (agent-peek connect " + key + ")" : "not installed"}`);
  }

  console.log(`
macOS grants permissions to the app that runs peek (Claude.app, Codex.app, or your terminal), not to peek itself.
In System Settings → Privacy & Security, turn that app on under:
  • Accessibility      — read window text
  • Screen Recording   — screenshots and windows on other Spaces
  • Full Disk Access   — Messages history (skip if you connected with --no-messages)
Then restart the app.${flags.openSettings ? "" : "\nRun `agent-peek doctor --open-settings` to open those panes."}`);
  if (flags.openSettings) for (const url of Object.values(SETTINGS)) await run("open", [url]);
}

function help() {
  console.log(`agent-peek — let your local agents see what's open on your Mac

Usage:
  agent-peek connect [agent...] [--no-messages] [--block "App,App"]   Connect peek to agents (default: every agent found)
  agent-peek disconnect [agent...]                                Remove peek from agents (default: all)
  agent-peek doctor [--open-settings]                             Check the helper, connections and permissions
  agent-peek serve                                                Run the MCP server on stdio (what agents call)

Agents: ${Object.keys(AGENTS).join(", ")}, all`);
}

const [cmd, ...rest] = process.argv.slice(2);
const flags = parseFlags(rest);
try {
  if (cmd === "serve" || (!cmd && !process.stdin.isTTY)) await import("./server.mjs");
  else if (cmd === "connect") await connect(flags);
  else if (cmd === "disconnect") await disconnect(flags);
  else if (cmd === "doctor") await doctor(flags);
  else help();
} catch (e) {
  console.error(e.message);
  process.exit(1);
}

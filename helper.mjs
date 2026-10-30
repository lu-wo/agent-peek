// Runs the native helper as its own app, "Agent Peek.app", through LaunchServices.
// Launched that way, macOS treats Agent Peek as the responsible app for permissions, so users grant
// Accessibility, Screen Recording and Full Disk Access once to Agent Peek instead of to every agent host.
// (Agent hosts such as the Claude app disclaim responsibility for their child processes, so permissions
// granted to the host often never reach a helper started as a plain child process.)
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

export const run = promisify(execFile);
export const APP = join(dirname(fileURLToPath(import.meta.url)), "helper", "Agent Peek.app");

const GATEKEEPER_HINT =
  "macOS may have blocked Agent Peek because it isn't notarized yet. Open System Settings → Privacy & Security, scroll to Security, " +
  `click "Allow Anyway" next to Agent Peek, then retry. Installing with the install script avoids this. App: ${APP}`;

export async function withTmp(fn) {
  const dir = await mkdtemp(join(tmpdir(), "peek-"));
  try {
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function helper(...args) {
  return withTmp(async (dir) => {
    const outPath = join(dir, "out.json");
    // -n: a fresh instance per call, so calls can overlap; -g -j: never activate or show anything; -W: wait for it to exit.
    const launch = await run("open", ["-n", "-g", "-j", "-W", "--stdout", outPath, "--stderr", join(dir, "err.txt"), "-a", APP, "--args", ...args], { timeout: 30000 })
      .then(() => null)
      .catch((e) => e);
    const stdout = await readFile(outPath, "utf8").catch(() => "");
    // Gatekeeper either refuses to launch a quarantined app or holds it behind a dialog until we time out; both leave no output.
    if (!stdout.trim()) throw new Error(launch ? `${GATEKEEPER_HINT}\n(${(launch.stderr || launch.message).trim()})` : "Agent Peek exited without output.");
    const out = JSON.parse(stdout);
    if (out.error) throw new Error(out.error);
    return out;
  });
}

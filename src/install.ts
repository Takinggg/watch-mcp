import { spawnSync } from "node:child_process";
import { accessSync, constants, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WatchError } from "./errors.ts";

/**
 * `watch-mcp install`: registers the MCP server in every AI client found on this machine,
 * so an agent (or a person) can set everything up from the repository URL alone.
 * Each change is idempotent and every edited file is backed up first.
 */

export const SERVER_NAME = "watch";

export type ClientId = "claude-code" | "codex" | "claude-desktop" | "cursor";

export interface ServerCommand {
  command: string;
  args: string[];
}

export interface InstallStep {
  client: ClientId;
  label: string;
  /** "absent": client not found; "ok": already set up; "add"/"update": change to make;
   *  "blocked": the client must be closed first. */
  action: "absent" | "ok" | "add" | "update" | "remove" | "blocked";
  detail: string;
  apply?: () => void;
}

interface Env {
  home: string;
  /** Finds an executable on PATH. */
  which: (name: string) => string | null;
  /** Runs a command, returning its exit code and output (used for the `claude` CLI). */
  run: (bin: string, args: string[]) => { status: number; stdout: string };
  /** Whether Claude Desktop is open (it keeps its settings file in memory and writes it back). */
  claudeDesktopOpen: () => boolean;
}

export function realEnv(): Env {
  return {
    home: os.homedir(),
    which: (name) => findOnPath(name),
    run: (bin, args) => {
      const out = spawnSync(bin, args, { encoding: "utf8", timeout: 30_000 });
      return { status: out.status ?? 1, stdout: `${out.stdout ?? ""}${out.stderr ?? ""}` };
    },
    claudeDesktopOpen: () => {
      if (process.platform !== "darwin") return false;
      const ps = spawnSync("ps", ["-axo", "comm="], { encoding: "utf8", timeout: 10_000 });
      return (ps.stdout ?? "").split("\n").some((line) => line.trim().endsWith("/Claude.app/Contents/MacOS/Claude"));
    },
  };
}

function findOnPath(name: string): string | null {
  const dirs = [...(process.env.PATH ?? "").split(path.delimiter), "/opt/homebrew/bin", "/usr/local/bin"];
  for (const dir of dirs.filter((d) => d.length > 0)) {
    const file = path.join(dir, name);
    try {
      accessSync(file, constants.X_OK);
      return file;
    } catch {
      // Not in this directory.
    }
  }
  return null;
}

/**
 * How clients should start the server. From an npx install: `npx -y watch-mcp`; from a
 * repository checkout: `node <checkout>/dist/cli.js`. Absolute paths, because apps opened
 * from the Dock (Claude Desktop, Codex) do not get the terminal's PATH.
 */
export function serverCommand(env: Env, override?: string): ServerCommand {
  if (override && override.trim().length > 0) {
    const [command, ...args] = override.trim().split(/\s+/);
    return { command: command as string, args };
  }
  const cli = fileURLToPath(new URL(import.meta.url.endsWith(".ts") ? "../dist/cli.js" : "./cli.js", import.meta.url));
  const fromRegistry = cli.includes(`${path.sep}_npx${path.sep}`) || cli.includes(`${path.sep}node_modules${path.sep}`);
  if (fromRegistry) return { command: env.which("npx") ?? "npx", args: ["-y", "watch-mcp"] };
  return { command: env.which("node") ?? process.execPath, args: [cli] };
}

export function planInstall(env: Env, server: ServerCommand, only?: ClientId[]): InstallStep[] {
  const steps = [claudeCodeStep(env, server), codexStep(env, server), jsonStep(env, server, "claude-desktop"), jsonStep(env, server, "cursor")];
  return only ? steps.filter((s) => only.includes(s.client)) : steps;
}

export function planUninstall(env: Env, only?: ClientId[]): InstallStep[] {
  const steps = [claudeCodeRemove(env), codexRemove(env), jsonRemove(env, "claude-desktop"), jsonRemove(env, "cursor")];
  return only ? steps.filter((s) => only.includes(s.client)) : steps;
}

// --- Claude Code: through its own CLI ---

function claudeCodeStep(env: Env, server: ServerCommand): InstallStep {
  const label = "Claude Code";
  const claude = env.which("claude");
  if (!claude) return { client: "claude-code", label, action: "absent", detail: "`claude` command not found" };
  const existing = env.run(claude, ["mcp", "get", SERVER_NAME]);
  const wanted = [server.command, ...server.args].join(" ");
  if (existing.status === 0 && claudeCodeRuns(existing.stdout, server)) {
    return { client: "claude-code", label, action: "ok", detail: "already set up" };
  }
  const update = existing.status === 0;
  return {
    client: "claude-code",
    label,
    action: update ? "update" : "add",
    detail: `claude mcp add -s user ${SERVER_NAME} -- ${wanted}`,
    apply: () => {
      if (update) env.run(claude, ["mcp", "remove", "-s", "user", SERVER_NAME]);
      const out = env.run(claude, ["mcp", "add", "-s", "user", SERVER_NAME, "--", server.command, ...server.args]);
      if (out.status !== 0) throw new WatchError("BAD_ARGUMENT", `claude mcp add failed: ${out.stdout.trim().split("\n").pop() ?? ""}`);
    },
  };
}

/** `claude mcp get` prints the command and its arguments on separate lines ("Command: ...", "Args: ..."). */
function claudeCodeRuns(output: string, server: ServerCommand): boolean {
  const field = (name: string) => new RegExp(`^\\s*${name}:[ \\t]*(.*)$`, "m").exec(output)?.[1]?.trim() ?? "";
  return field("Command") === server.command && field("Args") === server.args.join(" ");
}

function claudeCodeRemove(env: Env): InstallStep {
  const claude = env.which("claude");
  if (!claude || env.run(claude, ["mcp", "get", SERVER_NAME]).status !== 0) {
    return { client: "claude-code", label: "Claude Code", action: "absent", detail: "not set up" };
  }
  return {
    client: "claude-code",
    label: "Claude Code",
    action: "remove",
    detail: `claude mcp remove -s user ${SERVER_NAME}`,
    apply: () => void env.run(claude, ["mcp", "remove", "-s", "user", SERVER_NAME]),
  };
}

// --- Codex: ~/.codex/config.toml ---

function codexConfig(env: Env): string {
  return path.join(process.env.CODEX_HOME ?? path.join(env.home, ".codex"), "config.toml");
}

export function codexBlock(server: ServerCommand): string {
  const quote = (s: string): string => JSON.stringify(s);
  return [
    `[mcp_servers.${SERVER_NAME}]`,
    `command = ${quote(server.command)}`,
    `args = [${server.args.map(quote).join(", ")}]`,
    // The first npx start can download the package: give it time.
    "startup_timeout_sec = 60",
    "",
  ].join("\n");
}

/** Text with our [mcp_servers.watch] table (and its sub-tables) replaced by `block`, or removed. */
export function replaceTomlTable(text: string, block: string | null): string {
  const lines = text.split("\n");
  const header = `[mcp_servers.${SERVER_NAME}]`;
  const isOurs = (line: string): boolean => {
    const t = line.trim();
    return t === header || t.startsWith(`[mcp_servers.${SERVER_NAME}.`);
  };
  const out: string[] = [];
  let skipping = false;
  for (const line of lines) {
    if (line.trim().startsWith("[")) skipping = isOurs(line);
    if (!skipping) out.push(line);
  }
  let result = out.join("\n").replace(/\n{3,}$/, "\n\n");
  if (block) result = `${result.replace(/\s*$/, "")}\n\n${block}`;
  return result.startsWith("\n") ? result.trimStart() : result;
}

function codexStep(env: Env, server: ServerCommand): InstallStep {
  const file = codexConfig(env);
  const label = "Codex";
  if (!existsSync(path.dirname(file))) return { client: "codex", label, action: "absent", detail: "~/.codex not found" };
  const text = existsSync(file) ? readFileSync(file, "utf8") : "";
  const block = codexBlock(server);
  if (text.includes(block.trim())) return { client: "codex", label, action: "ok", detail: "already set up" };
  const update = text.split("\n").some((l) => l.trim() === `[mcp_servers.${SERVER_NAME}]`);
  return {
    client: "codex",
    label,
    action: update ? "update" : "add",
    detail: `${update ? "update" : "add"} [mcp_servers.${SERVER_NAME}] in ${file}`,
    apply: () => writeWithBackup(file, replaceTomlTable(text, block)),
  };
}

function codexRemove(env: Env): InstallStep {
  const file = codexConfig(env);
  const text = existsSync(file) ? readFileSync(file, "utf8") : "";
  if (!text.split("\n").some((l) => l.trim() === `[mcp_servers.${SERVER_NAME}]`)) {
    return { client: "codex", label: "Codex", action: "absent", detail: "not set up" };
  }
  return { client: "codex", label: "Codex", action: "remove", detail: `remove from ${file}`, apply: () => writeWithBackup(file, replaceTomlTable(text, null)) };
}

// --- Claude Desktop and Cursor: JSON with an "mcpServers" object ---

function jsonFile(env: Env, client: "claude-desktop" | "cursor"): { file: string; label: string; present: boolean } {
  if (client === "cursor") {
    const dir = path.join(env.home, ".cursor");
    return { file: path.join(dir, "mcp.json"), label: "Cursor", present: existsSync(dir) };
  }
  const dir =
    process.platform === "win32"
      ? path.join(process.env.APPDATA ?? path.join(env.home, "AppData", "Roaming"), "Claude")
      : path.join(env.home, "Library", "Application Support", "Claude");
  return { file: path.join(dir, "claude_desktop_config.json"), label: "Claude Desktop", present: existsSync(dir) };
}

function readJsonObject(file: string): Record<string, unknown> {
  if (!existsSync(file)) return {};
  try {
    const value = JSON.parse(readFileSync(file, "utf8")) as unknown;
    return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  } catch {
    throw new WatchError("BAD_ARGUMENT", `${file} is not valid JSON; fix it or add watch-mcp by hand (see README).`);
  }
}

function jsonStep(env: Env, server: ServerCommand, client: "claude-desktop" | "cursor"): InstallStep {
  const { file, label, present } = jsonFile(env, client);
  if (!present) return { client, label, action: "absent", detail: "not installed" };
  const config = readJsonObject(file);
  const servers = (config.mcpServers ?? {}) as Record<string, unknown>;
  const wanted = { command: server.command, args: server.args };
  if (JSON.stringify(servers[SERVER_NAME]) === JSON.stringify(wanted)) return { client, label, action: "ok", detail: "already set up" };
  if (client === "claude-desktop" && env.claudeDesktopOpen()) return desktopOpen(label);
  const update = SERVER_NAME in servers;
  return {
    client,
    label,
    action: update ? "update" : "add",
    detail: `${update ? "update" : "add"} mcpServers.${SERVER_NAME} in ${file}${client === "claude-desktop" ? " (restart Claude Desktop)" : ""}`,
    apply: () => writeWithBackup(file, `${JSON.stringify({ ...config, mcpServers: { ...servers, [SERVER_NAME]: wanted } }, null, 2)}\n`),
  };
}

function jsonRemove(env: Env, client: "claude-desktop" | "cursor"): InstallStep {
  const { file, label } = jsonFile(env, client);
  const config = existsSync(file) ? readJsonObject(file) : {};
  const servers = (config.mcpServers ?? {}) as Record<string, unknown>;
  if (!(SERVER_NAME in servers)) return { client, label, action: "absent", detail: "not set up" };
  if (client === "claude-desktop" && env.claudeDesktopOpen()) return desktopOpen(label);
  const { [SERVER_NAME]: _removed, ...rest } = servers;
  return { client, label, action: "remove", detail: `remove from ${file}`, apply: () => writeWithBackup(file, `${JSON.stringify({ ...config, mcpServers: rest }, null, 2)}\n`) };
}

/**
 * While Claude Desktop is open it writes its settings file back from memory, which drops a change
 * made from outside (seen right after an install, and again later).
 */
function desktopOpen(label: string): InstallStep {
  return { client: "claude-desktop", label, action: "blocked", detail: "quit Claude Desktop first (while open it rewrites its settings file and drops the change), then run this again" };
}

/** Keeps the previous version next to the file (<name>.watch-mcp.bak) before replacing it. */
function writeWithBackup(file: string, content: string): void {
  mkdirSync(path.dirname(file), { recursive: true });
  if (existsSync(file)) copyFileSync(file, `${file}.watch-mcp.bak`);
  writeFileSync(file, content);
}

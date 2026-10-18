import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { codexBlock, planInstall, planUninstall, replaceTomlTable } from "../src/install.ts";

const SERVER = { command: "/opt/homebrew/bin/npx", args: ["-y", "watch-mcp"] };

/** A fake home with Codex, Claude Desktop and Cursor folders, and a fake `claude` CLI that logs its calls. */
/** What `claude mcp get watch` prints (Claude Code 2.1). */
function claudeGet(command: string, args: string): string {
  return `watch:\n  Scope: User config (available in all your projects)\n  Status: ✔ Connected\n  Type: stdio\n  Command: ${command}\n  Args: ${args}\n  Environment:\n\nTo remove this server, run: claude mcp remove watch -s user\n`;
}

function fakeEnv(options: { claudeHas?: string } = {}) {
  const home = mkdtempSync(path.join(os.tmpdir(), "watch-install-"));
  const codexDir = path.join(home, ".codex");
  mkdirSync(codexDir);
  writeFileSync(path.join(codexDir, "config.toml"), 'model = "x"\n\n[mcp_servers.other]\ncommand = "other"\n\n[projects."/tmp"]\ntrust_level = "trusted"\n');
  mkdirSync(path.join(home, "Library", "Application Support", "Claude"), { recursive: true });
  writeFileSync(path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json"), JSON.stringify({ mcpServers: { other: { command: "x" } }, theme: "dark" }));
  mkdirSync(path.join(home, ".cursor"));
  const calls: string[][] = [];
  const env = {
    home,
    which: (name: string) => (name === "claude" ? "/fake/claude" : null),
    run: (_bin: string, args: string[]) => {
      calls.push(args);
      if (args[1] === "get") return options.claudeHas ? { status: 0, stdout: options.claudeHas } : { status: 1, stdout: "No MCP server found" };
      return { status: 0, stdout: "" };
    },
  };
  process.env.CODEX_HOME = codexDir;
  return { env, home, calls, codexFile: path.join(codexDir, "config.toml") };
}

describe("install into AI clients", () => {
  it("adds watch-mcp to Claude Code, Codex, Claude Desktop and Cursor, keeping other settings", () => {
    const { env, home, calls, codexFile } = fakeEnv();
    const steps = planInstall(env, SERVER);
    assert.deepEqual(steps.map((s) => [s.client, s.action]), [["claude-code", "add"], ["codex", "add"], ["claude-desktop", "add"], ["cursor", "add"]]);
    for (const step of steps) step.apply?.();
    assert.deepEqual(calls.at(-1), ["mcp", "add", "-s", "user", "watch", "--", "/opt/homebrew/bin/npx", "-y", "watch-mcp"]);
    const toml = readFileSync(codexFile, "utf8");
    assert.match(toml, /\[mcp_servers\.other\]\ncommand = "other"/);
    assert.match(toml, /\[projects\."\/tmp"\]\ntrust_level = "trusted"/);
    assert.ok(toml.includes(codexBlock(SERVER).trim()));
    assert.ok(existsSync(`${codexFile}.watch-mcp.bak`), "backup written");
    const desktop = JSON.parse(readFileSync(path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json"), "utf8"));
    assert.deepEqual(desktop, { mcpServers: { other: { command: "x" }, watch: { command: SERVER.command, args: SERVER.args } }, theme: "dark" });
    assert.deepEqual(JSON.parse(readFileSync(path.join(home, ".cursor", "mcp.json"), "utf8")).mcpServers.watch, { command: SERVER.command, args: SERVER.args });
  });

  it("is idempotent: a second run changes nothing", () => {
    const { env } = fakeEnv({ claudeHas: claudeGet(SERVER.command, SERVER.args.join(" ")) });
    for (const step of planInstall(env, SERVER)) step.apply?.();
    const again = planInstall(env, SERVER);
    assert.deepEqual(again.map((s) => s.action), ["ok", "ok", "ok", "ok"]);
  });

  it("sees an older command in Claude Code as an update", () => {
    const { env } = fakeEnv({ claudeHas: claudeGet("node", "/old/cli.js") });
    assert.equal(planInstall(env, SERVER)[0]?.action, "update");
  });

  it("updates an old entry instead of duplicating it", () => {
    const { env, codexFile } = fakeEnv();
    for (const step of planInstall(env, { command: "node", args: ["/old/cli.js"] })) step.apply?.();
    for (const step of planInstall(env, SERVER)) step.apply?.();
    const toml = readFileSync(codexFile, "utf8");
    assert.equal(toml.split("[mcp_servers.watch]").length - 1, 1);
    assert.doesNotMatch(toml, /old\/cli\.js/);
  });

  it("skips clients that are not installed", () => {
    const home = mkdtempSync(path.join(os.tmpdir(), "watch-install-empty-"));
    process.env.CODEX_HOME = path.join(home, ".codex");
    const steps = planInstall({ home, which: () => null, run: () => ({ status: 1, stdout: "" }) }, SERVER);
    assert.deepEqual(steps.map((s) => s.action), ["absent", "absent", "absent", "absent"]);
  });

  it("uninstall removes only watch-mcp", () => {
    const { env, home, codexFile } = fakeEnv();
    for (const step of planInstall(env, SERVER)) step.apply?.();
    for (const step of planUninstall(env, ["codex", "claude-desktop"])) step.apply?.();
    const toml = readFileSync(codexFile, "utf8");
    assert.doesNotMatch(toml, /mcp_servers\.watch/);
    assert.match(toml, /\[mcp_servers\.other\]/);
    const desktop = JSON.parse(readFileSync(path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json"), "utf8"));
    assert.deepEqual(Object.keys(desktop.mcpServers), ["other"]);
  });

  it("replaceTomlTable also drops sub-tables like [mcp_servers.watch.env]", () => {
    const text = '[a]\nx = 1\n\n[mcp_servers.watch]\ncommand = "old"\n\n[mcp_servers.watch.env]\nK = "v"\n\n[b]\ny = 2\n';
    const out = replaceTomlTable(text, null);
    assert.doesNotMatch(out, /watch/);
    assert.match(out, /\[a\]\nx = 1/);
    assert.match(out, /\[b\]\ny = 2/);
  });
});

#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { getBinaries } from "./binaries.ts";
import { dataRoot } from "./cache.ts";
import { describeError } from "./errors.ts";
import { finalizeBundle } from "./finalize.ts";
import { planInstall, planUninstall, realEnv, serverCommand, type ClientId } from "./install.ts";
import { run } from "./exec.ts";
import { createServer } from "./server.ts";
import { describeTranscript, getTranscript, transcriptLines } from "./transcribe.ts";
import { selectBackend } from "./transcribers/index.ts";
import { loadVideo, watchVideo } from "./watch.ts";

const require = createRequire(import.meta.url);
const pkg = require("../package.json") as { version: string };

const HELP = `watch-mcp ${pkg.version}: let Claude watch local videos.

Usage:
  watch-mcp                 Start the MCP server on stdio (what Claude Code / Desktop / Cursor run)
  watch-mcp install [--dry-run] [--json] [--client claude-code,codex,claude-desktop,cursor] [--command "..."]
                            Add watch-mcp to every AI client found here (Claude Code, Codex,
                            Claude Desktop, Cursor). Idempotent; edited files are backed up.
  watch-mcp uninstall [--dry-run] [--client ...]
                            Remove it from those clients
  watch-mcp setup           Download the speech models now instead of on first use
  watch-mcp doctor          Show which ffmpeg, models and cache folder are used
  watch-mcp watch <video> [--budget N] [--out DIR]
                            Render the storyboards + timeline to DIR (default ./watch-output)
  watch-mcp transcribe <video> [--json] [--language xx]
                            Print the timestamped transcript
  watch-mcp finalize <bundle.watch> [--json]
                            Transcribe a recording bundle and write its timeline (used by WatchRecorder)

Install in Claude Code:  claude mcp add watch -- npx -y watch-mcp
`;

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  if (command === undefined) return serve();
  if (command === "--help" || command === "-h" || command === "help") return print(HELP);
  if (command === "--version" || command === "-v") return print(pkg.version);
  if (command === "setup") return setup();
  if (command === "install" || command === "uninstall") return installCommand(command, rest);
  if (command === "doctor") return doctor();
  if (command === "watch") return watchToFolder(rest);
  if (command === "transcribe") return transcribeToStdout(rest);
  if (command === "finalize") return finalizeToStdout(rest);
  process.stderr.write(`Unknown command "${command}".\n\n${HELP}`);
  return 2;
}

async function serve(): Promise<number> {
  const server = createServer();
  await server.connect(new StdioServerTransport());
  process.stderr.write(`[watch-mcp] ${pkg.version} ready on stdio\n`);
  // Keep running until the client closes stdin.
  return new Promise<number>(() => undefined);
}

function print(text: string): number {
  process.stdout.write(`${text.trimEnd()}\n`);
  return 0;
}

function installCommand(command: "install" | "uninstall", args: string[]): number {
  const env = realEnv();
  const clients = valueOf(args, "--client")?.split(",").map((c) => c.trim()) as ClientId[] | undefined;
  const valid: ClientId[] = ["claude-code", "codex", "claude-desktop", "cursor"];
  if (clients?.some((c) => !valid.includes(c))) {
    process.stderr.write(`--client must be one or more of: ${valid.join(", ")}\n`);
    return 2;
  }
  const dryRun = args.includes("--dry-run");
  const steps = command === "install" ? planInstall(env, serverCommand(env, valueOf(args, "--command")), clients) : planUninstall(env, clients);
  if (args.includes("--json")) {
    for (const step of steps) if (step.apply && !dryRun) step.apply();
    const report = steps.map((s) => ({ client: s.client, label: s.label, action: s.action, detail: s.detail, applied: Boolean(s.apply) && !dryRun }));
    return print(JSON.stringify(report));
  }
  for (const step of steps) {
    const mark = step.action === "absent" ? "-" : step.action === "ok" ? "ok" : dryRun ? "would" : "done";
    if (step.apply && !dryRun) step.apply();
    print(`${mark.padEnd(5)} ${step.label.padEnd(15)} ${step.action === "absent" || step.action === "ok" ? step.detail : `${step.action}: ${step.detail}`}`);
  }
  if (command === "install" && !steps.some((s) => s.action !== "absent")) {
    print("No AI client found. Add watch-mcp by hand: see the README (Install).");
  }
  if (dryRun) print("(dry run: nothing was changed)");
  return 0;
}

async function setup(): Promise<number> {
  const backend = selectBackend();
  if (!backend.availability().ready) {
    let lastPct = -1;
    await backend.prepare((message, fraction) => {
      const pct = Math.floor(fraction * 100);
      if (pct !== lastPct && pct % 5 === 0) process.stderr.write(`\r${message} ${pct}%`);
      lastPct = pct;
    });
    process.stderr.write("\n");
  }
  return print(`ok  speech-to-text ready: ${backend.label}`);
}

async function doctor(): Promise<number> {
  const bins = getBinaries();
  for (const [name, bin] of [["ffmpeg", bins.ffmpeg], ["ffprobe", bins.ffprobe]] as const) {
    const { stdout } = await run(bin, { label: name, args: ["-version"], timeoutMs: 10_000 });
    const firstLine = stdout.toString("utf8").split("\n")[0] ?? "";
    print(`${name}: ${bin} (${bins.source[name]}) ${firstLine}`);
  }
  const backend = selectBackend();
  const availability = backend.availability();
  print(`speech-to-text: ${backend.label} (${availability.ready ? "ready" : `not ready: ${availability.message}`})`);
  print(`data folder: ${dataRoot()}`);
  print(`platform: ${process.platform}-${process.arch}, node ${process.version}`);
  return 0;
}

async function watchToFolder(args: string[]): Promise<number> {
  const file = args.find((a) => !a.startsWith("--"));
  if (!file) {
    print(HELP);
    return 2;
  }
  const budgetArg = valueOf(args, "--budget");
  const outDir = path.resolve(valueOf(args, "--out") ?? "watch-output");
  const result = await watchVideo({
    path: file,
    budget: budgetArg === undefined ? undefined : Number(budgetArg),
    onProgress: (message, fraction) => process.stderr.write(`\r${Math.round(fraction * 100)}% ${message}`.padEnd(60)),
  });
  process.stderr.write("\n");
  mkdirSync(outDir, { recursive: true });
  result.images.forEach((image, i) => writeFileSync(path.join(outDir, `storyboard-${i + 1}.jpg`), image.jpeg));
  const captions = result.images.map((image, i) => `storyboard-${i + 1}.jpg: ${image.caption}`);
  writeFileSync(path.join(outDir, "timeline.txt"), [result.intro, "", ...captions, "", result.outro, ""].join("\n"));
  print(`Wrote ${result.images.length} storyboard(s) and timeline.txt to ${outDir}`);
  return 0;
}

async function transcribeToStdout(args: string[]): Promise<number> {
  const file = args.find((a, i) => !a.startsWith("--") && args[i - 1] !== "--language");
  if (!file) {
    print(HELP);
    return 2;
  }
  const { info, fp } = await loadVideo(file);
  const result = await getTranscript(info, fp, {
    language: valueOf(args, "--language"),
    waitForModel: true,
    onProgress: (message, fraction) => process.stderr.write(`\r${Math.round(fraction * 100)}% ${message}`.padEnd(60)),
  });
  process.stderr.write("\n");
  if (args.includes("--json")) {
    const segments = result.kind === "ok" ? result.segments : [];
    const language = result.kind === "ok" ? result.language : null;
    const text = segments.map((s) => s.text).join(" ");
    return print(JSON.stringify({ status: result.kind, message: describeTranscript(result), language, duration: info.duration, text, segments }));
  }
  return print([describeTranscript(result), ...transcriptLines(result, { start: 0, end: info.duration }, info.duration >= 3600)].join("\n"));
}

async function finalizeToStdout(args: string[]): Promise<number> {
  const dir = args.find((a) => !a.startsWith("--"));
  if (!dir) {
    print(HELP);
    return 2;
  }
  const summary = await finalizeBundle(dir, (message, fraction) => process.stderr.write(`\r${Math.round(fraction * 100)}% ${message}`.padEnd(60)));
  process.stderr.write("\n");
  if (args.includes("--json")) return print(JSON.stringify(summary));
  return print(`${summary.message}\n${summary.keyframes} keyframes written to timeline.json`);
}

function valueOf(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    process.stderr.write(`watch-mcp: ${describeError(err)}\n`);
    process.exitCode = 1;
  },
);

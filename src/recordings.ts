import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { dataRoot } from "./cache.ts";
import { WatchError } from "./errors.ts";

/** Written by the macOS companion (WatchRecorder) each time a recording stops. */
export interface LatestRecording {
  version: 1;
  /** Absolute path of the .mov file. */
  path: string;
  /** ISO 8601 start time. */
  startedAt: string;
  /** Seconds. */
  duration: number;
  /** What the user said, as plain text, or null when nothing was transcribed. */
  transcript: string | null;
}

/**
 * Folder shared with the companion. Application Support (not Caches) on macOS,
 * because macOS may purge caches. Override with WATCH_MCP_STATE_DIR.
 */
export function stateDir(): string {
  const override = process.env.WATCH_MCP_STATE_DIR;
  if (override && override.trim().length > 0) return path.resolve(override);
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support", "watch-mcp");
  return dataRoot();
}

export function latestRecordingFile(): string {
  return path.join(stateDir(), "latest-recording.json");
}

export function readLatestRecording(): LatestRecording | null {
  const file = latestRecordingFile();
  if (!existsSync(file)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    throw new WatchError("BAD_ARGUMENT", "The latest-recording file is not valid JSON; record again.");
  }
  return validate(parsed);
}

function validate(value: unknown): LatestRecording {
  const v = value as Partial<LatestRecording> | null;
  const ok =
    v !== null &&
    typeof v === "object" &&
    v.version === 1 &&
    typeof v.path === "string" &&
    path.isAbsolute(v.path) &&
    typeof v.startedAt === "string" &&
    Number.isFinite(Date.parse(v.startedAt)) &&
    typeof v.duration === "number" &&
    Number.isFinite(v.duration) &&
    (v.transcript === null || typeof v.transcript === "string");
  if (!ok) throw new WatchError("BAD_ARGUMENT", "The latest-recording file has an unexpected format; record again.");
  return v as LatestRecording;
}

/** "3 min ago", "2 h ago"... for the tool header. */
export function ago(iso: string, now: number = Date.now()): string {
  const seconds = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  if (seconds < 90) return `${seconds} s ago`;
  if (seconds < 90 * 60) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 36 * 3600) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} days ago`;
}

import { createHash } from "node:crypto";
import { mkdirSync, openSync, readFileSync, readSync, closeSync, renameSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Root folder for models and cached results (override with WATCH_MCP_HOME). */
export function dataRoot(): string {
  const override = process.env.WATCH_MCP_HOME;
  if (override && override.trim().length > 0) return path.resolve(override);
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Caches", "watch-mcp");
  if (process.platform === "win32") {
    return path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"), "watch-mcp");
  }
  return path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), ".cache"), "watch-mcp");
}

/** Cached storyboards and transcripts (override with WATCH_MCP_CACHE_DIR, e.g. in tests). */
export function cacheDir(): string {
  const override = process.env.WATCH_MCP_CACHE_DIR;
  return ensureDir(override && override.trim().length > 0 ? path.resolve(override) : path.join(dataRoot(), "results"));
}

export function modelsDir(): string {
  return ensureDir(path.join(dataRoot(), "models"));
}

export function ensureDir(dir: string): string {
  mkdirSync(dir, { recursive: true });
  return dir;
}

const CHUNK = 64 * 1024;
const SAMPLES = 32;

/**
 * Content fingerprint of a video: its size plus 32 evenly spaced 64 KiB chunks
 * (including the first and last). Moving or renaming the file keeps the cache;
 * editing it changes the fingerprint. Reads at most 2 MiB, whatever the file size.
 */
export function fingerprint(file: string, sizeBytes: number): string {
  const hash = createHash("sha256");
  hash.update(`size:${sizeBytes}\n`);
  const fd = openSync(file, "r");
  try {
    const buffer = Buffer.alloc(CHUNK);
    const lastStart = Math.max(0, sizeBytes - CHUNK);
    for (let i = 0; i < SAMPLES; i += 1) {
      const position = Math.floor((lastStart * i) / (SAMPLES - 1));
      const read = readSync(fd, buffer, 0, CHUNK, position);
      hash.update(buffer.subarray(0, read));
      if (lastStart === 0) break;
    }
  } finally {
    closeSync(fd);
  }
  return hash.digest("hex").slice(0, 32);
}

/** Stable key for a fingerprint plus the parameters that shape a result. */
export function resultKey(kind: string, fp: string, params: Record<string, unknown>): string {
  const sorted = Object.keys(params)
    .sort()
    .map((k) => `${k}=${JSON.stringify(params[k])}`)
    .join("&");
  return createHash("sha256").update(`${kind}|${fp}|${sorted}`).digest("hex").slice(0, 40);
}

export function readCached<T>(key: string, file: string): T | null {
  try {
    return JSON.parse(readFileSync(path.join(cacheDir(), key, file), "utf8")) as T;
  } catch {
    // Missing or unreadable cache entry: recompute.
    return null;
  }
}

export function readCachedBinary(key: string, file: string): Buffer | null {
  try {
    return readFileSync(path.join(cacheDir(), key, file));
  } catch {
    // Missing cache entry: recompute.
    return null;
  }
}

/** Writes atomically (temp file + rename) so a crash never leaves a half-written entry. */
export function writeCached(key: string, file: string, data: string | Buffer): void {
  const dir = ensureDir(path.join(cacheDir(), key));
  const target = path.join(dir, file);
  const temp = `${target}.${process.pid}.tmp`;
  writeFileSync(temp, data);
  renameSync(temp, target);
}

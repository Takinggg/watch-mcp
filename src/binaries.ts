import { accessSync, constants, existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { WatchError } from "./errors.ts";

const require = createRequire(import.meta.url);

export interface Binaries {
  ffmpeg: string;
  ffprobe: string;
  source: { ffmpeg: BinarySource; ffprobe: BinarySource };
}

export type BinarySource = "env" | "bundled" | "path";

let cached: Binaries | null = null;

/**
 * Finds ffmpeg and ffprobe. Order: environment override, the copies bundled
 * with the npm package (ffmpeg-static, @ffprobe-installer), then PATH.
 */
export function getBinaries(): Binaries {
  if (cached) return cached;
  const ffmpeg = resolveBinary("ffmpeg", process.env.WATCH_MCP_FFMPEG, bundledFfmpeg);
  const ffprobe = resolveBinary("ffprobe", process.env.WATCH_MCP_FFPROBE, bundledFfprobe);
  cached = {
    ffmpeg: ffmpeg.path,
    ffprobe: ffprobe.path,
    source: { ffmpeg: ffmpeg.source, ffprobe: ffprobe.source },
  };
  return cached;
}

function resolveBinary(
  name: string,
  override: string | undefined,
  bundled: () => string | null,
): { path: string; source: BinarySource } {
  if (override && override.trim().length > 0) {
    if (!isExecutable(override)) {
      throw new WatchError("FFMPEG_MISSING", `The ${name} path set in the environment is not an executable file.`);
    }
    return { path: override, source: "env" };
  }
  const fromPackage = bundled();
  if (fromPackage) return { path: fromPackage, source: "bundled" };
  const fromPath = findOnPath(name);
  if (fromPath) return { path: fromPath, source: "path" };
  throw new WatchError(
    "FFMPEG_MISSING",
    `${name} was not found. Reinstall watch-mcp (its bundled ${name} download may have been blocked) or install ffmpeg (macOS: brew install ffmpeg).`,
  );
}

function bundledFfmpeg(): string | null {
  try {
    const found = require("ffmpeg-static") as string | null;
    return found && isExecutable(found) ? found : null;
  } catch {
    // Package missing or no build for this platform: fall back to PATH.
    return null;
  }
}

function bundledFfprobe(): string | null {
  try {
    const found = require("@ffprobe-installer/ffprobe") as { path?: string };
    return found.path && isExecutable(found.path) ? found.path : null;
  } catch {
    // The installer throws on platforms it does not ship: fall back to PATH.
    return null;
  }
}

function findOnPath(name: string): string | null {
  const dirs = (process.env.PATH ?? "").split(path.delimiter).filter((dir) => dir.length > 0);
  const extra = process.platform === "darwin" ? ["/opt/homebrew/bin", "/usr/local/bin"] : [];
  const exe = process.platform === "win32" ? `${name}.exe` : name;
  for (const dir of [...dirs, ...extra]) {
    const candidate = path.join(dir, exe);
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

function isExecutable(file: string): boolean {
  if (!existsSync(file)) return false;
  try {
    accessSync(file, constants.X_OK);
    return true;
  } catch {
    // Exists but not executable (or not accessible): treat as missing.
    return false;
  }
}

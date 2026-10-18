import os from "node:os";
import { getBinaries } from "./binaries.ts";
import { WatchError } from "./errors.ts";
import { mapLimit, run } from "./exec.ts";
import type { VideoInfo } from "./probe.ts";

/** A region of the frame, as fractions (0..1) of the displayed width and height. */
export interface Crop {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface FrameSize {
  width: number;
  height: number;
}

export function validateCrop(crop: Crop): Crop {
  const values = [crop.x, crop.y, crop.width, crop.height];
  const finite = values.every((v) => Number.isFinite(v) && v >= 0 && v <= 1);
  if (!finite || crop.width <= 0 || crop.height <= 0 || crop.x + crop.width > 1.0001 || crop.y + crop.height > 1.0001) {
    throw new WatchError("BAD_ARGUMENT", "crop must be fractions of the frame: 0 <= x, y and x + width <= 1, y + height <= 1.");
  }
  return crop;
}

/** Pixel size of the (optionally cropped) picture, scaled to fit maxEdge while keeping its aspect ratio. */
export function fitSize(info: VideoInfo, maxEdge: number, crop?: Crop): FrameSize {
  const srcW = info.width * (crop?.width ?? 1);
  const srcH = info.height * (crop?.height ?? 1);
  const scale = Math.min(1, maxEdge / Math.max(srcW, srcH));
  return { width: evenAtLeast2(srcW * scale), height: evenAtLeast2(srcH * scale) };
}

function evenAtLeast2(value: number): number {
  return Math.max(2, Math.floor(value / 2) * 2);
}

function filterFor(size: FrameSize, crop?: Crop): string {
  const parts: string[] = [];
  if (crop) {
    const f = (v: number): string => v.toFixed(6);
    parts.push(`crop=w=iw*${f(crop.width)}:h=ih*${f(crop.height)}:x=iw*${f(crop.x)}:y=ih*${f(crop.y)}`);
  }
  parts.push(`scale=${size.width}:${size.height}:flags=lanczos`, "setsar=1");
  return parts.join(",");
}

export interface ExtractOptions {
  size: FrameSize;
  crop?: Crop | undefined;
  signal?: AbortSignal | undefined;
}

/**
 * Decodes the frame shown at `time` (seconds from the start) as RGB24.
 * Seeking past the last frame yields nothing, so it retries slightly earlier.
 */
export async function extractFrameRgb(info: VideoInfo, time: number, opts: ExtractOptions): Promise<Buffer> {
  const expected = opts.size.width * opts.size.height * 3;
  const step = Math.max(0.25, 2 / info.fps);
  let t = Math.max(0, Math.min(time, info.duration > 0 ? info.duration - 1 / info.fps : time));
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const out = await decodeOne(info, t, opts);
    if (out.length === expected) return out;
    if (t === 0) break;
    t = Math.max(0, t - step * (attempt + 1));
  }
  throw new WatchError("FFMPEG_FAILED", `Could not decode a frame near ${time.toFixed(2)} s.`);
}

async function decodeOne(info: VideoInfo, time: number, opts: ExtractOptions): Promise<Buffer> {
  const { ffmpeg } = getBinaries();
  const expected = opts.size.width * opts.size.height * 3;
  const { stdout } = await run(ffmpeg, {
    label: "ffmpeg",
    args: [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-ss", time.toFixed(3), "-i", `file:${info.path}`,
      "-map", "0:v:0", "-frames:v", "1", "-an", "-sn", "-dn",
      "-vf", filterFor(opts.size, opts.crop),
      "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ],
    timeoutMs: 60_000,
    signal: opts.signal,
    maxStdoutBytes: expected + 1024,
  });
  return stdout;
}

/** Extracts several frames in parallel; results keep the order of `times`. */
export async function extractFramesRgb(info: VideoInfo, times: readonly number[], opts: ExtractOptions): Promise<Buffer[]> {
  const limit = Math.max(2, Math.min(8, Math.floor(os.availableParallelism() / 2)));
  return mapLimit(times, limit, (t) => extractFrameRgb(info, t, opts));
}

export interface IndexedRange {
  start: number;
  end: number;
  /** Analysis frame rate: indices refer to the frames an `fps` filter emits from `start`. */
  fps: number;
  indices: readonly number[];
}

/**
 * Re-decodes the range once and keeps only the analysis samples at `indices`, so the tiles
 * are exactly the frames that were analysed. Cheaper than seeking when the range is short.
 */
export async function extractAtIndices(info: VideoInfo, range: IndexedRange, opts: ExtractOptions): Promise<Buffer[]> {
  const { ffmpeg } = getBinaries();
  const frameBytes = opts.size.width * opts.size.height * 3;
  const span = Math.max(0.001, range.end - range.start);
  const select = range.indices.map((i) => `eq(n\\,${i})`).join("+");
  const { stdout } = await run(ffmpeg, {
    label: "ffmpeg",
    args: [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-ss", range.start.toFixed(3), "-i", `file:${info.path}`, "-t", span.toFixed(3),
      "-map", "0:v:0", "-an", "-sn", "-dn",
      "-vf", `fps=${range.fps.toFixed(6)},select='${select}',${filterFor(opts.size, opts.crop)}`,
      // Without passthrough ffmpeg would duplicate frames to keep a constant rate.
      "-fps_mode", "passthrough",
      "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ],
    timeoutMs: 120_000 + span * 2000,
    signal: opts.signal,
    maxStdoutBytes: frameBytes * (range.indices.length + 1),
  });
  const frames: Buffer[] = [];
  for (let offset = 0; offset + frameBytes <= stdout.length; offset += frameBytes) {
    frames.push(stdout.subarray(offset, offset + frameBytes));
  }
  return frames;
}

/**
 * Decodes every frame between start and end at `fps` in a single pass (used by zoom,
 * where frames are close together and one sequential decode beats many seeks).
 */
export async function decodeRangeRgb(info: VideoInfo, range: { start: number; end: number; fps: number }, opts: ExtractOptions): Promise<Buffer[]> {
  const { ffmpeg } = getBinaries();
  const frameBytes = opts.size.width * opts.size.height * 3;
  const span = Math.max(0.001, range.end - range.start);
  const maxFrames = Math.ceil(span * range.fps) + 2;
  const { stdout } = await run(ffmpeg, {
    label: "ffmpeg",
    args: [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-ss", range.start.toFixed(3), "-i", `file:${info.path}`, "-t", span.toFixed(3),
      "-map", "0:v:0", "-an", "-sn", "-dn",
      "-vf", `fps=${range.fps.toFixed(6)},${filterFor(opts.size, opts.crop)}`,
      "-frames:v", String(maxFrames),
      "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ],
    timeoutMs: 120_000,
    signal: opts.signal,
    maxStdoutBytes: frameBytes * (maxFrames + 1),
  });
  const frames: Buffer[] = [];
  for (let offset = 0; offset + frameBytes <= stdout.length; offset += frameBytes) {
    frames.push(stdout.subarray(offset, offset + frameBytes));
  }
  return frames;
}

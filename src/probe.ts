import { statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getBinaries } from "./binaries.ts";
import { WatchError } from "./errors.ts";
import { run } from "./exec.ts";

export interface VideoInfo {
  path: string;
  name: string;
  sizeBytes: number;
  mtimeMs: number;
  container: string;
  /** Seconds. */
  duration: number;
  /** Display size: rotation and non-square pixels already applied. */
  width: number;
  height: number;
  fps: number;
  codec: string;
  hasAudio: boolean;
  audioCodec: string | null;
}

/** Containers ffmpeg reports for the formats we accept (mp4/mov, mkv/webm, plus a few common ones). */
const ALLOWED_CONTAINERS = ["mov", "mp4", "m4a", "3gp", "3g2", "mj2", "matroska", "webm", "avi", "mpegts", "flv"];

/** Resolves a user-given path (absolute, ~/..., relative or file://) to an existing file or folder. */
export function resolveLocalPath(input: string, cwd: string = process.cwd()): string {
  const raw = input.trim();
  if (raw.length === 0) throw new WatchError("BAD_ARGUMENT", "path is empty.");
  if (/^https?:\/\//i.test(raw)) {
    throw new WatchError("BAD_ARGUMENT", "watch-mcp only reads local files. Download the video first, then pass its path.");
  }
  let resolved = raw;
  if (raw.startsWith("file://")) resolved = fileURLToPath(raw);
  else if (raw === "~" || raw.startsWith("~/")) resolved = path.join(os.homedir(), raw.slice(1));
  resolved = path.resolve(cwd, resolved);
  try {
    statSync(resolved);
  } catch {
    throw new WatchError("NOT_FOUND", `No file at ${resolved}. Pass an absolute path to the video.`);
  }
  return resolved;
}

interface ProbeStream {
  codec_type?: string;
  codec_name?: string;
  width?: number;
  height?: number;
  avg_frame_rate?: string;
  r_frame_rate?: string;
  duration?: string;
  sample_aspect_ratio?: string;
  tags?: Record<string, string>;
  side_data_list?: Array<{ rotation?: number }>;
  disposition?: { attached_pic?: number };
}

interface ProbeOutput {
  streams?: ProbeStream[];
  format?: { format_name?: string; duration?: string };
}

export async function probeVideo(file: string, signal?: AbortSignal): Promise<VideoInfo> {
  const { ffprobe } = getBinaries();
  const { stdout } = await run(ffprobe, {
    label: "ffprobe",
    args: ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", `file:${file}`],
    timeoutMs: 30_000,
    signal,
    maxStdoutBytes: 4 * 1024 * 1024,
  }).catch((err: unknown) => {
    if (err instanceof WatchError && err.code === "FFMPEG_FAILED") {
      throw new WatchError("UNSUPPORTED", `${path.basename(file)} is not a readable video (ffprobe could not parse it).`);
    }
    throw err;
  });
  const parsed = JSON.parse(stdout.toString("utf8")) as ProbeOutput;
  const stats = statSync(file);
  return buildInfo(file, parsed, { sizeBytes: stats.size, mtimeMs: stats.mtimeMs });
}

/** Pure part of probing, exported for tests. */
export function buildInfo(file: string, probe: ProbeOutput, stat: { sizeBytes: number; mtimeMs: number }): VideoInfo {
  const container = probe.format?.format_name ?? "unknown";
  const families = container.split(",");
  if (!families.some((family) => ALLOWED_CONTAINERS.includes(family))) {
    throw new WatchError("UNSUPPORTED", `Unsupported container "${container}". Supported: mp4, mov, mkv, webm (also avi, ts, flv).`);
  }
  const streams = probe.streams ?? [];
  const video = streams.find((s) => s.codec_type === "video" && s.disposition?.attached_pic !== 1);
  if (!video || !video.width || !video.height) {
    throw new WatchError("NO_VIDEO", `${path.basename(file)} has no video stream.`);
  }
  const audio = streams.find((s) => s.codec_type === "audio");
  const { width, height } = displaySize(video);
  const duration = firstFinite([probe.format?.duration, video.duration]);
  return {
    path: file,
    name: path.basename(file),
    sizeBytes: stat.sizeBytes,
    mtimeMs: stat.mtimeMs,
    container,
    duration: duration ?? 0,
    width,
    height,
    fps: frameRate(video),
    codec: video.codec_name ?? "unknown",
    hasAudio: audio !== undefined,
    audioCodec: audio?.codec_name ?? null,
  };
}

function displaySize(video: ProbeStream): { width: number; height: number } {
  let width = video.width ?? 0;
  const height = video.height ?? 0;
  const sar = parseRatio(video.sample_aspect_ratio);
  if (sar !== null && sar > 0 && Math.abs(sar - 1) > 0.01) width = Math.round(width * sar);
  const rotation = rotationOf(video);
  return Math.abs(rotation) % 180 === 90 ? { width: height, height: width } : { width, height };
}

function rotationOf(video: ProbeStream): number {
  const fromSideData = video.side_data_list?.find((d) => typeof d.rotation === "number")?.rotation;
  if (typeof fromSideData === "number") return fromSideData;
  const fromTag = Number(video.tags?.rotate ?? "0");
  return Number.isFinite(fromTag) ? fromTag : 0;
}

function frameRate(video: ProbeStream): number {
  for (const candidate of [video.avg_frame_rate, video.r_frame_rate]) {
    const value = parseRatio(candidate);
    if (value !== null && value > 0 && value < 1000) return value;
  }
  return 30;
}

function parseRatio(text: string | undefined): number | null {
  if (!text) return null;
  const [num, den] = text.split(/[/:]/).map(Number);
  if (num === undefined || den === undefined || !Number.isFinite(num) || !Number.isFinite(den) || den === 0) return null;
  return num / den;
}

function firstFinite(values: Array<string | undefined>): number | null {
  for (const value of values) {
    const parsed = value === undefined ? Number.NaN : Number(value);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return null;
}

/**
 * Some files (WebM from browsers, fragmented MP4) carry no duration.
 * Decoding the video stream once without output gives the real length.
 */
export async function measureDuration(file: string, signal?: AbortSignal): Promise<number> {
  const { ffmpeg } = getBinaries();
  const { stderr } = await run(ffmpeg, {
    label: "ffmpeg",
    args: ["-hide_banner", "-nostdin", "-i", `file:${file}`, "-map", "0:v:0", "-c", "copy", "-f", "null", "-"],
    timeoutMs: 120_000,
    signal,
  });
  const times = [...stderr.matchAll(/time=(\d+):(\d+):(\d+(?:\.\d+)?)/g)];
  const last = times.at(-1);
  if (!last) throw new WatchError("UNSUPPORTED", "Could not determine the video duration.");
  const seconds = Number(last[1]) * 3600 + Number(last[2]) * 60 + Number(last[3]);
  if (!Number.isFinite(seconds) || seconds <= 0) throw new WatchError("UNSUPPORTED", "Could not determine the video duration.");
  return seconds;
}

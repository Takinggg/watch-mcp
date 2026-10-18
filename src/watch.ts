import { createHash } from "node:crypto";
import { statSync } from "node:fs";
import path from "node:path";
import { computeSignatures } from "./analyze.ts";
import { isBundleDir, isQuality, readBundle, type Bundle, type BundleEvent, type Quality } from "./bundle.ts";
import { fingerprint, readCached, readCachedBinary, resultKey, writeCached } from "./cache.ts";
import { encodeJpeg } from "./encode.ts";
import { WatchError } from "./errors.ts";
import { extractAtIndices, extractFramesRgb, type FrameSize } from "./frames.ts";
import { measureDuration, probeVideo, resolveLocalPath, type VideoInfo } from "./probe.ts";
import { selectKeyframes } from "./select.ts";
import { chooseGrid, composeSheet, layoutSheet, type TileGrid } from "./storyboard.ts";
import { formatTime } from "./time.ts";
import { getTranscript, type TranscriptResult } from "./transcribe.ts";
import { buildTimeline, type TimelineFrame } from "./timeline.ts";

export interface ImageOut {
  caption: string;
  jpeg: Buffer;
}

export interface ToolOutput {
  /** Text shown before the images. */
  intro: string;
  images: ImageOut[];
  /** Text shown after the images. */
  outro: string;
}

export type ProgressFn = (message: string, fraction: number) => void;

export interface WatchParams {
  path: string;
  budget?: number | undefined;
  start?: number | undefined;
  end?: number | undefined;
  transcript?: boolean | undefined;
  language?: string | undefined;
  /** Wait for the speech model instead of returning "pending" (CLI, bundle finalize). */
  waitForModel?: boolean | undefined;
  signal?: AbortSignal | undefined;
  onProgress?: ProgressFn | undefined;
}

/** Bump when selection or rendering changes, so stale cached sheets are not reused. */
const RENDER_VERSION = 4;
export const SHEET_MAX_EDGE = 1568;
export const TILES_PER_SHEET = 16;
/** 8 storyboards: ~17k image tokens by the API formula, under Claude Code's default 25k MCP output cap. */
export const MAX_BUDGET = 128;
const GUTTER = 4;

/** Keyframe rules per recording preset (kept in step with companion/Sources/WatchRecorder/Quality.swift). */
const QUALITY_RULES: Record<Quality, { secondsPerKeyframe: number; maxKeyframes: number }> = {
  light: { secondsPerKeyframe: 6, maxKeyframes: 32 },
  balanced: { secondsPerKeyframe: 3, maxKeyframes: 64 },
  detailed: { secondsPerKeyframe: 1.5, maxKeyframes: 128 },
};

/**
 * About one keyframe per 3 s (per the bundle's quality preset when there is one), rounded up
 * to whole storyboards (16 tiles cost the same image tokens as 13), capped per preset.
 */
export function defaultBudget(span: number, quality: Quality = "balanced"): number {
  const rule = QUALITY_RULES[quality];
  const sheets = Math.max(1, Math.ceil(span / rule.secondsPerKeyframe / TILES_PER_SHEET));
  return Math.min(rule.maxKeyframes, sheets * TILES_PER_SHEET);
}

export interface LoadedVideo {
  info: VideoInfo;
  fp: string;
  /** Set when the path is a .watch recording bundle (its video is in info.path). */
  bundle: Bundle | null;
}

/** Accepts a video file or a .watch recording bundle folder. */
export async function loadVideo(input: string, signal?: AbortSignal): Promise<LoadedVideo> {
  const target = resolveLocalPath(input);
  let bundle: Bundle | null = null;
  let file = target;
  if (statSync(target).isDirectory()) {
    if (!isBundleDir(target)) {
      throw new WatchError("BAD_ARGUMENT", `${target} is a folder, not a video file or a .watch recording bundle.`);
    }
    bundle = readBundle(target);
    file = bundle.videoPath;
  }
  const info = await probeVideo(file, signal);
  if (!(info.duration > 0)) info.duration = await measureDuration(file, signal);
  return { info, fp: fingerprint(file, info.sizeBytes), bundle };
}

export function clampRange(info: VideoInfo, start?: number, end?: number): { start: number; end: number } {
  const s = Math.min(Math.max(0, start ?? 0), info.duration);
  const e = Math.min(Math.max(0, end ?? info.duration), info.duration);
  if (e - s < 0.05) {
    throw new WatchError("BAD_ARGUMENT", `Empty range: start must be before end, within 0 and ${formatTime(info.duration)}.`);
  }
  return { start: s, end: e };
}

export interface VisualMeta {
  frames: TimelineFrame[];
  sheets: Array<{ caption: string; file: string }>;
  analysis: { samples: number; fps: number };
}

export interface WatchCore {
  loaded: LoadedVideo;
  range: { start: number; end: number };
  budget: number;
  visual: VisualMeta;
  transcript: TranscriptResult;
  events: BundleEvent[];
  key: string;
}

/** Everything watch_video computes, before it is turned into text and images. */
export async function watchCore(params: WatchParams): Promise<WatchCore> {
  const progress = params.onProgress ?? (() => undefined);
  progress("Reading video", 0.02);
  const loaded = await loadVideo(params.path, params.signal);
  const { info, fp } = loaded;
  const range = clampRange(info, params.start, params.end);
  const span = range.end - range.start;
  const quality = isQuality(loaded.bundle?.manifest.quality) ? loaded.bundle.manifest.quality : undefined;
  const budget = Math.min(MAX_BUDGET, Math.max(4, Math.floor(params.budget ?? defaultBudget(span, quality))));
  const events = loaded.bundle?.timeline.events ?? [];
  const clicks = events.filter((e): e is ClickEvent => e.type === "click" && e.t >= range.start && e.t <= range.end);
  const key = resultKey("watch", fp, { v: RENDER_VERSION, start: range.start, end: range.end, budget, clicks: digest(clicks) });

  const visual = await loadOrRenderVisual(info, { key, range, budget, clicks, signal: params.signal, progress });
  const transcript = await maybeTranscript(loaded, params, progress);
  progress("Done", 1);
  return { loaded, range, budget, visual, transcript, events, key };
}

export async function watchVideo(params: WatchParams): Promise<ToolOutput> {
  const core = await watchCore(params);
  const { info, bundle } = core.loaded;
  const images = core.visual.sheets.map((sheet) => {
    const jpeg = readCachedBinary(core.key, sheet.file);
    if (!jpeg) throw new WatchError("FFMPEG_FAILED", "A cached storyboard image went missing; call watch_video again.");
    return { caption: sheet.caption, jpeg };
  });
  const facts = { range: core.range, budget: core.budget, frameCount: core.visual.frames.length, sheetCount: images.length, analysis: core.visual.analysis };
  const bundleLine = bundle
    ? `RECORDING BUNDLE ${path.basename(bundle.dir)}: ${core.events.length} recorded input event(s) (clicks, typing, app switches) appear as DONE in the timeline; clicks are circled in yellow on the storyboards.\n`
    : "";
  return {
    intro: bundleLine + introText(info, facts),
    images,
    outro: buildTimeline({ info, frames: core.visual.frames, transcript: core.transcript, range: core.range, events: core.events }),
  };
}

type ClickEvent = Extract<BundleEvent, { type: "click" }>;

function digest(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex").slice(0, 16);
}

interface RenderJob {
  key: string;
  range: { start: number; end: number };
  budget: number;
  clicks: readonly ClickEvent[];
  signal?: AbortSignal | undefined;
  progress: ProgressFn;
}

async function loadOrRenderVisual(info: VideoInfo, job: RenderJob): Promise<VisualMeta> {
  const cached = readCached<VisualMeta>(job.key, "meta.json");
  if (cached) return cached;

  job.progress("Scanning for changes", 0.05);
  const sigs = await computeSignatures(info, {
    start: job.range.start,
    end: job.range.end,
    signal: job.signal,
    onProgress: (done, total) => job.progress("Scanning for changes", 0.05 + 0.45 * Math.min(1, done / total)),
  });
  if (sigs.sigs.length === 0) throw new WatchError("FFMPEG_FAILED", "No frames could be decoded from this video.");
  // The sample showing the moment of each click (the pointer on its target) is always kept.
  const last = sigs.sigs.length - 1;
  const forced = job.clicks.map((c) => Math.min(last, Math.max(0, Math.floor((c.t - job.range.start) * sigs.fps))));
  // Pauses shorter than ~1 s do not split an episode (e.g. a cursor moving, then a click).
  const picked = selectKeyframes(sigs.sigs, { budget: job.budget, mergeGapSamples: Math.max(1, Math.round(sigs.fps)), forced });
  const frames: TimelineFrame[] = picked.map((p, i) => ({
    n: i + 1,
    t: sigs.times[p.index] ?? job.range.start,
    change: p.change,
    cut: p.cut,
    sameUntil: sigs.times[p.sameUntil] ?? job.range.end,
    sheet: Math.floor(i / TILES_PER_SHEET) + 1,
  }));
  attachClickMarks(frames, job.clicks, 1.5 / sigs.fps);

  job.progress(`Extracting ${frames.length} keyframes`, 0.55);
  const grid = chooseGrid(info.width / info.height, { perSheet: TILES_PER_SHEET, maxEdge: SHEET_MAX_EDGE, gutter: GUTTER });
  const size = { width: grid.tileW, height: grid.tileH };
  const tiles = await extractTiles(info, { range: job.range, fps: sigs.fps, indices: picked.map((p) => p.index), times: frames.map((f) => f.t) }, size, job.signal);
  job.progress("Composing storyboards", 0.85);
  const sheets = await renderSheets({ grid, frames, tiles, key: job.key, withHours: info.duration >= 3600, signal: job.signal });
  const meta: VisualMeta = { frames, sheets, analysis: { samples: sigs.sigs.length, fps: sigs.fps } };
  writeCached(job.key, "meta.json", JSON.stringify(meta));
  return meta;
}

/** Circles each click on the keyframe closest to it (when one is within `window` seconds). */
export function attachClickMarks(frames: TimelineFrame[], clicks: readonly ClickEvent[], window: number): void {
  for (const click of clicks) {
    let best: TimelineFrame | undefined;
    for (const frame of frames) {
      if (frame.t > click.t + window) break;
      if (!best || Math.abs(frame.t - click.t) < Math.abs(best.t - click.t)) best = frame;
    }
    if (best && Math.abs(best.t - click.t) <= Math.max(window, 0.6)) (best.marks ??= []).push({ x: click.x, y: click.y });
  }
}

/** Up to this span, one sequential decode is cheaper than seeking to each keyframe. */
const SINGLE_PASS_MAX_SPAN = 600;

interface TileSource {
  range: { start: number; end: number };
  fps: number;
  indices: number[];
  times: number[];
}

async function extractTiles(info: VideoInfo, src: TileSource, size: FrameSize, signal?: AbortSignal): Promise<Buffer[]> {
  if (src.range.end - src.range.start <= SINGLE_PASS_MAX_SPAN) {
    const tiles = await extractAtIndices(info, { ...src.range, fps: src.fps, indices: src.indices }, { size, signal });
    if (tiles.length === src.indices.length) return tiles;
    // Frame counts can disagree on files with broken timestamps: fall back to exact seeks.
  }
  return extractFramesRgb(info, src.times, { size, signal });
}

interface SheetJob {
  grid: TileGrid;
  frames: TimelineFrame[];
  tiles: Buffer[];
  key: string;
  withHours: boolean;
  signal?: AbortSignal | undefined;
  decimals?: number;
}

/** Packs frames into sheets of up to 16 labelled tiles and stores the JPEGs in the cache entry. */
export async function renderSheets(job: SheetJob): Promise<Array<{ caption: string; file: string }>> {
  const out: Array<{ caption: string; file: string }> = [];
  const total = Math.ceil(job.frames.length / TILES_PER_SHEET);
  for (let s = 0; s < total; s += 1) {
    const frames = job.frames.slice(s * TILES_PER_SHEET, (s + 1) * TILES_PER_SHEET);
    const tiles = job.tiles.slice(s * TILES_PER_SHEET, (s + 1) * TILES_PER_SHEET);
    const decimals = job.decimals ?? 1;
    const layout = layoutSheet(job.grid, frames.length);
    const canvas = composeSheet(
      layout,
      frames.map((f, i) => ({ rgb: tiles[i] as Buffer, label: `#${f.n} ${formatTime(f.t, decimals, job.withHours)}`, marks: f.marks })),
    );
    const jpeg = await encodeJpeg(canvas, "sheet", job.signal);
    const file = `sheet-${s + 1}.jpg`;
    writeCached(job.key, file, jpeg);
    const first = frames[0] as TimelineFrame;
    const last = frames.at(-1) as TimelineFrame;
    out.push({
      caption: `Storyboard ${s + 1}/${total}: frames #${first.n}-#${last.n} (${formatTime(first.t, decimals, job.withHours)} to ${formatTime(last.t, decimals, job.withHours)}), read left to right, top to bottom.`,
      file,
    });
  }
  return out;
}

async function maybeTranscript(loaded: LoadedVideo, params: WatchParams, progress: ProgressFn): Promise<TranscriptResult> {
  if (params.transcript === false) return { kind: "skipped", reason: "transcript: false was requested" };
  // A bundle that already carries its transcript (from WatchRecorder or another producer) is used as is.
  const speech = loaded.bundle?.timeline.speech;
  if (speech && params.language === undefined) {
    const label = `(from the recording bundle, ${speech.source})`;
    return speech.segments.length === 0
      ? { kind: "no-speech", source: speech.source, label }
      : { kind: "ok", source: speech.source, label, language: speech.language, segments: speech.segments, words: speech.words };
  }
  return getTranscript(loaded.info, loaded.fp, {
    language: params.language,
    signal: params.signal,
    waitForModel: params.waitForModel ?? false,
    onProgress: (message, fraction) => progress(message, 0.9 + 0.09 * fraction),
  });
}

interface IntroFacts {
  range: { start: number; end: number };
  budget: number;
  frameCount: number;
  sheetCount: number;
  analysis: { samples: number; fps: number };
}

function introText(info: VideoInfo, facts: IntroFacts): string {
  const withHours = info.duration >= 3600;
  const partial = facts.range.start > 0 || facts.range.end < info.duration;
  const audio = info.hasAudio ? `audio ${info.audioCodec ?? "yes"}` : "no audio track";
  const lines = [
    `VIDEO ${info.name}: ${formatTime(info.duration, 1, withHours)}, ${info.width}x${info.height}, ${round(info.fps)} fps, ${info.codec}, ${audio}.`,
    partial ? `Range watched: ${formatTime(facts.range.start, 1, withHours)} to ${formatTime(facts.range.end, 1, withHours)}.` : "",
    `${facts.frameCount} keyframes (budget ${facts.budget}) on ${facts.sheetCount} storyboard image(s). Frames were picked where the picture changes (scanned ${facts.analysis.samples} samples at ${round(facts.analysis.fps)} fps); static stretches are collapsed and reported in the timeline. Each tile is labelled "#frame mm:ss.s".`,
    `Drill down: zoom(path, start, end) shows dense consecutive frames to see motion; frame(path, t, crop) returns one full-resolution still for small text.`,
  ];
  return lines.filter((line) => line.length > 0).join("\n");
}

function round(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}


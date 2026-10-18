import { readCached, readCachedBinary, resultKey, writeCached } from "./cache.ts";
import { encodeJpeg } from "./encode.ts";
import { WatchError } from "./errors.ts";
import { decodeRangeRgb, extractFrameRgb, fitSize, validateCrop, type Crop } from "./frames.ts";
import { chooseGrid } from "./storyboard.ts";
import { formatTime } from "./time.ts";
import { peekTranscript, transcriptLines } from "./transcribe.ts";
import { createHash } from "node:crypto";
import type { BundleEvent } from "./bundle.ts";
import { describeEvent, type TimelineFrame } from "./timeline.ts";
import { attachClickMarks, clampRange, loadVideo, renderSheets, SHEET_MAX_EDGE, TILES_PER_SHEET, type ProgressFn, type ToolOutput } from "./watch.ts";

export const MAX_ZOOM_FRAMES = 48;
export const MAX_FRAME_EDGE = 2000;
const ZOOM_VERSION = 2;

export interface ZoomParams {
  path: string;
  start: number;
  end: number;
  fps?: number | undefined;
  crop?: Crop | undefined;
  signal?: AbortSignal | undefined;
  onProgress?: ProgressFn | undefined;
}

/** Effective sampling rate for a zoom: as asked, but never above the source rate or the frame cap. */
export function zoomFps(span: number, sourceFps: number, requested?: number): number {
  const cap = MAX_ZOOM_FRAMES / Math.max(span, 0.001);
  const wanted = requested !== undefined && requested > 0 ? requested : Math.min(sourceFps, cap);
  return Math.max(0.1, Math.min(wanted, sourceFps, cap));
}

export async function zoomVideo(params: ZoomParams): Promise<ToolOutput> {
  const progress = params.onProgress ?? (() => undefined);
  const crop = params.crop ? validateCrop(params.crop) : undefined;
  const { info, fp, bundle } = await loadVideo(params.path, params.signal);
  const range = clampRange(info, params.start, params.end);
  const span = range.end - range.start;
  const fps = zoomFps(span, info.fps, params.fps);
  const events = (bundle?.timeline.events ?? []).filter((e) => e.t >= range.start && e.t <= range.end);
  // Click marks are drawn in full-frame coordinates, so they are skipped on cropped zooms.
  const clicks = crop ? [] : events.filter((e): e is Extract<BundleEvent, { type: "click" }> => e.type === "click");
  const clickDigest = createHash("sha256").update(JSON.stringify(clicks)).digest("hex").slice(0, 16);
  const key = resultKey("zoom", fp, { v: ZOOM_VERSION, start: range.start, end: range.end, fps, crop: crop ?? null, clicks: clickDigest });

  let meta = readCached<{ frames: TimelineFrame[]; sheets: Array<{ caption: string; file: string }> }>(key, "meta.json");
  if (!meta) {
    progress("Decoding segment", 0.1);
    const aspect = (info.width * (crop?.width ?? 1)) / (info.height * (crop?.height ?? 1));
    const grid = chooseGrid(aspect, { perSheet: TILES_PER_SHEET, maxEdge: SHEET_MAX_EDGE, gutter: 4 });
    const tiles = (await decodeRangeRgb(info, { start: range.start, end: range.end, fps }, { size: { width: grid.tileW, height: grid.tileH }, crop, signal: params.signal })).slice(0, MAX_ZOOM_FRAMES);
    if (tiles.length === 0) throw new WatchError("FFMPEG_FAILED", "No frames could be decoded in that range.");
    const frames: TimelineFrame[] = tiles.map((_, i) => ({ n: i + 1, t: range.start + i / fps, change: 0, cut: false, sameUntil: range.start + i / fps, sheet: Math.floor(i / TILES_PER_SHEET) + 1 }));
    attachClickMarks(frames, clicks, 1 / fps);
    progress("Composing storyboards", 0.7);
    const sheets = await renderSheets({ grid, frames, tiles, key, withHours: info.duration >= 3600, signal: params.signal, decimals: 2 });
    meta = { frames, sheets };
    writeCached(key, "meta.json", JSON.stringify(meta));
  }
  const images = meta.sheets.map((sheet) => ({ caption: sheet.caption, jpeg: mustRead(key, sheet.file) }));
  const withHours = info.duration >= 3600;
  const reduced = params.fps !== undefined && fps < params.fps - 1e-6;
  const intro = [
    `ZOOM ${info.name}: ${formatTime(range.start, 2, withHours)} to ${formatTime(range.end, 2, withHours)} (${span.toFixed(2)} s), ${meta.frames.length} consecutive frames at ${fps.toFixed(2)} fps (source ${info.fps.toFixed(2)} fps)${crop ? `, cropped to ${describeCrop(crop)}` : ""}.`,
    reduced ? `The requested fps was lowered to stay within ${MAX_ZOOM_FRAMES} frames; zoom into a shorter range for a denser view.` : "",
    "Tiles are labelled \"#frame mm:ss.ss\"; compare neighbouring tiles to see motion, flicker or animation steps.",
  ].filter((l) => l.length > 0).join("\n");
  const transcript = peekTranscript(info, fp);
  const said = transcript ? transcriptLines(transcript, range, withHours).map((l) => `SAID ${l}`) : [];
  const done = events.map((e) => `DONE ${formatTime(e.t, 2, withHours)}  ${describeEvent(e)}`);
  const outro = said.length + done.length > 0 ? ["In this range:", ...done, ...said].join("\n") : "";
  return { intro, images, outro };
}

export interface FrameParams {
  path: string;
  t: number;
  crop?: Crop | undefined;
  maxEdge?: number | undefined;
  signal?: AbortSignal | undefined;
}

export async function frameStill(params: FrameParams): Promise<ToolOutput> {
  const crop = params.crop ? validateCrop(params.crop) : undefined;
  const { info } = await loadVideo(params.path, params.signal);
  if (params.t > info.duration + 0.001) {
    throw new WatchError("BAD_ARGUMENT", `t is after the end of the video (${formatTime(info.duration, 2)}).`);
  }
  const maxEdge = Math.min(MAX_FRAME_EDGE, Math.max(64, Math.floor(params.maxEdge ?? MAX_FRAME_EDGE)));
  const size = fitSize(info, maxEdge, crop);
  const rgb = await extractFrameRgb(info, params.t, { size, crop, signal: params.signal });
  const jpeg = await encodeJpeg({ data: rgb, width: size.width, height: size.height }, "detail", params.signal);
  const srcW = Math.round(info.width * (crop?.width ?? 1));
  const srcH = Math.round(info.height * (crop?.height ?? 1));
  const scaleNote = srcW === size.width ? "full resolution" : `downscaled from ${srcW}x${srcH}; use crop to read smaller details at full resolution`;
  const intro = `FRAME ${info.name} at ${formatTime(params.t, 3, info.duration >= 3600)}${crop ? `, region ${describeCrop(crop)}` : ""}: ${size.width}x${size.height} (${scaleNote}).`;
  return { intro, images: [{ caption: "", jpeg }], outro: "" };
}

function describeCrop(crop: Crop): string {
  const pct = (v: number): string => `${Math.round(v * 100)}%`;
  return `x ${pct(crop.x)}, y ${pct(crop.y)}, ${pct(crop.width)} wide, ${pct(crop.height)} tall`;
}

function mustRead(key: string, file: string): Buffer {
  const data = readCachedBinary(key, file);
  if (!data) throw new WatchError("FFMPEG_FAILED", "A cached image went missing; call the tool again.");
  return data;
}

import { existsSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { WatchError } from "./errors.ts";
import type { TimedText } from "./words.ts";

/**
 * A recording bundle (".watch"): a folder holding one video plus a timeline of
 * what was said and done, all on the video's clock (seconds from its first frame).
 *
 *   Recording.watch/
 *     manifest.json   {"format":"watch-bundle","version":1,"video":"video.mov",...}
 *     video.mov
 *     timeline.json   {"version":1,"events":[...],"speech":{...},"keyframes":[...]}
 *
 * The spec is in the README ("Recording bundles").
 */
export const BUNDLE_FORMAT = "watch-bundle";

export interface BundleManifest {
  format: typeof BUNDLE_FORMAT;
  version: 1;
  /** Video file, relative to the bundle folder. */
  video: string;
  createdAt: string;
  duration?: number;
  recorder?: { name: string; version: string };
  /** Recording preset; also sets how many keyframes watch_video shows by default. */
  quality?: Quality;
  width?: number;
  height?: number;
  fps?: number;
}

export type Quality = "light" | "balanced" | "detailed";

export function isQuality(value: unknown): value is Quality {
  return value === "light" || value === "balanced" || value === "detailed";
}

export type BundleEvent =
  /** x, y: position in the video frame, as fractions (0..1) from the top-left corner. */
  | { t: number; type: "click"; button: "left" | "right" | "other"; x: number; y: number; app?: string }
  /** A burst of typing: how many keys, never which ones. */
  | { t: number; type: "typing"; duration: number; keys: number; app?: string }
  /** A key pressed with modifiers, e.g. ["cmd"]; the key itself is not recorded. */
  | { t: number; type: "shortcut"; modifiers: string[]; app?: string }
  /** The frontmost app changed. */
  | { t: number; type: "app"; name: string };

export interface BundleSpeech {
  source: string;
  language: string | null;
  segments: TimedText[];
  words: TimedText[];
}

export interface BundleTimeline {
  version: 1;
  events: BundleEvent[];
  speech?: BundleSpeech;
  keyframes?: Array<{ t: number; change: number; cut: boolean }>;
}

export interface Bundle {
  dir: string;
  videoPath: string;
  manifest: BundleManifest;
  timeline: BundleTimeline;
}

const MAX_JSON_BYTES = 32 * 1024 * 1024;
const MAX_EVENTS = 200_000;

export function isBundleDir(dir: string): boolean {
  return existsSync(path.join(dir, "manifest.json")) && statSync(dir).isDirectory();
}

export function readBundle(dir: string): Bundle {
  const manifest = parseManifest(readJson(path.join(dir, "manifest.json"), "manifest.json"));
  const videoPath = path.join(dir, manifest.video);
  if (!existsSync(videoPath)) throw new WatchError("NOT_FOUND", `The bundle's video (${manifest.video}) is missing.`);
  // The video must live inside the bundle, even through symlinks.
  const realDir = realpathSync(dir);
  const realVideo = realpathSync(videoPath);
  if (!realVideo.startsWith(realDir + path.sep)) throw new WatchError("BAD_ARGUMENT", "The bundle's video must be inside the bundle folder.");
  const timelineFile = path.join(dir, "timeline.json");
  const timeline = existsSync(timelineFile) ? parseTimeline(readJson(timelineFile, "timeline.json")) : { version: 1 as const, events: [] };
  return { dir, videoPath: realVideo, manifest, timeline };
}

/**
 * Sets the speech and keyframes of timeline.json, keeping every other field and every event
 * as written by the recorder (including event types this version does not know).
 * Atomic: temp file + rename.
 */
export function updateTimeline(dir: string, patch: { speech?: BundleSpeech; keyframes?: BundleTimeline["keyframes"] }): void {
  const target = path.join(dir, "timeline.json");
  const raw = existsSync(target) ? (readJson(target, "timeline.json") as Record<string, unknown>) : { version: 1, events: [] };
  const next = { ...raw, ...patch };
  const temp = `${target}.${process.pid}.tmp`;
  writeFileSync(temp, `${JSON.stringify(next, null, 1)}\n`);
  renameSync(temp, target);
}

function readJson(file: string, name: string): unknown {
  const size = statSync(file).size;
  if (size > MAX_JSON_BYTES) throw new WatchError("BAD_ARGUMENT", `The bundle's ${name} is too large.`);
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    throw new WatchError("BAD_ARGUMENT", `The bundle's ${name} is not valid JSON.`);
  }
}

function parseManifest(value: unknown): BundleManifest {
  const m = value as Partial<BundleManifest> | null;
  const ok =
    m !== null &&
    typeof m === "object" &&
    m.format === BUNDLE_FORMAT &&
    m.version === 1 &&
    typeof m.video === "string" &&
    m.video.length > 0 &&
    !path.isAbsolute(m.video) &&
    !m.video.split(/[\\/]/).includes("..") &&
    typeof m.createdAt === "string";
  if (!ok) throw new WatchError("BAD_ARGUMENT", 'manifest.json must have format "watch-bundle", version 1, a relative "video" path and "createdAt".');
  return m as BundleManifest;
}

function parseTimeline(value: unknown): BundleTimeline {
  const t = value as Partial<BundleTimeline> | null;
  if (t === null || typeof t !== "object" || t.version !== 1 || !Array.isArray(t.events)) {
    throw new WatchError("BAD_ARGUMENT", 'timeline.json must have version 1 and an "events" array.');
  }
  if (t.events.length > MAX_EVENTS) throw new WatchError("BAD_ARGUMENT", "timeline.json has too many events.");
  // Unknown or malformed events are skipped, so newer recorders stay readable.
  const events = t.events.filter(isKnownEvent).sort((a, b) => a.t - b.t);
  return { ...t, version: 1, events } as BundleTimeline;
}

function isKnownEvent(value: unknown): value is BundleEvent {
  const e = value as Record<string, unknown> | null;
  if (e === null || typeof e !== "object" || !isTime(e.t)) return false;
  switch (e.type) {
    case "click":
      return isFraction(e.x) && isFraction(e.y) && (e.button === "left" || e.button === "right" || e.button === "other");
    case "typing":
      return isTime(e.duration) && typeof e.keys === "number" && Number.isInteger(e.keys) && e.keys >= 0;
    case "shortcut":
      return Array.isArray(e.modifiers) && e.modifiers.every((m) => typeof m === "string");
    case "app":
      return typeof e.name === "string";
    default:
      return false;
  }
}

function isTime(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0;
}

function isFraction(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;
}

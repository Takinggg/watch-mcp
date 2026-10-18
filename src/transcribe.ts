import { readCached, resultKey, writeCached } from "./cache.ts";
import { WatchError } from "./errors.ts";
import type { VideoInfo } from "./probe.ts";
import { formatTime } from "./time.ts";
import type { TranscriptionBackend } from "./transcribers/backend.ts";
import { selectBackend } from "./transcribers/index.ts";
import type { TimedText } from "./words.ts";

export type Segment = TimedText;

export type TranscriptResult =
  | { kind: "ok"; source: string; label: string; language: string | null; segments: TimedText[]; words: TimedText[] }
  | { kind: "no-speech"; source: string; label: string }
  | { kind: "no-audio" }
  | { kind: "skipped"; reason: string }
  | { kind: "pending"; message: string }
  | { kind: "unavailable"; message: string };

export interface TranscriptOptions {
  language?: string | undefined;
  signal?: AbortSignal | undefined;
  /** When false and the backend needs preparing (model download), start it and return "pending". */
  waitForModel: boolean;
  onProgress?: ((message: string, fraction: number) => void) | undefined;
}

const TRANSCRIPT_VERSION = 3;

export function transcriptionDisabled(): boolean {
  const flag = process.env.WATCH_MCP_TRANSCRIBE?.trim().toLowerCase();
  return flag === "0" || flag === "off" || flag === "false";
}

export async function getTranscript(info: VideoInfo, fp: string, opts: TranscriptOptions): Promise<TranscriptResult> {
  if (transcriptionDisabled()) return { kind: "skipped", reason: "WATCH_MCP_TRANSCRIBE is off" };
  if (!info.hasAudio) return { kind: "no-audio" };
  let backend: TranscriptionBackend;
  try {
    backend = selectBackend();
  } catch (err) {
    return { kind: "unavailable", message: err instanceof WatchError ? err.message : "Invalid transcription setting." };
  }
  const language = normalizeLanguage(opts.language);
  const key = resultKey("transcript", fp, { v: TRANSCRIPT_VERSION, backend: backend.id, language });
  const cached = readCached<TranscriptResult>(key, "transcript.json");
  if (cached) return cached;

  const availability = backend.availability();
  if (!availability.ready) {
    if (!availability.canPrepare) return { kind: "unavailable", message: availability.message };
    if (!opts.waitForModel) {
      void backend.prepare().catch(() => undefined);
      return { kind: "pending", message: availability.message };
    }
  }
  try {
    await backend.prepare((message, fraction) => opts.onProgress?.(message, fraction * 0.5));
    const raw = await runExclusive(() => backend.transcribe({ info, language, signal: opts.signal, onProgress: opts.onProgress }));
    const result: TranscriptResult =
      raw.segments.length === 0
        ? { kind: "no-speech", source: backend.id, label: backend.label }
        : { kind: "ok", source: backend.id, label: backend.label, language: raw.language, segments: raw.segments, words: raw.words };
    writeCached(key, "transcript.json", JSON.stringify(result));
    // Alias so other tools (zoom) can reuse the latest transcript of this file without transcribing again.
    writeCached(resultKey("transcript-latest", fp, { v: TRANSCRIPT_VERSION }), "transcript.json", JSON.stringify(result));
    return result;
  } catch (err) {
    if (err instanceof WatchError && err.code === "CANCELLED") throw err;
    return { kind: "unavailable", message: err instanceof WatchError ? err.message : "Transcription failed." };
  }
}

/** The most recent transcript computed for this file, if any (never transcribes). */
export function peekTranscript(info: VideoInfo, fp: string): TranscriptResult | null {
  if (!info.hasAudio) return null;
  return readCached<TranscriptResult>(resultKey("transcript-latest", fp, { v: TRANSCRIPT_VERSION }), "transcript.json");
}

function normalizeLanguage(language: string | undefined): string {
  const value = (language ?? "auto").trim().toLowerCase();
  if (value === "" || value === "auto") return "auto";
  if (!/^[a-z]{2,3}$/.test(value)) throw new WatchError("BAD_ARGUMENT", 'language must be a 2-letter code such as "en", "fr", "ko", or "auto".');
  return value;
}

let queue: Promise<unknown> = Promise.resolve();

/** One transcription at a time: a local model saturates the GPU, so parallel runs only slow each other down. */
function runExclusive<T>(task: () => Promise<T>): Promise<T> {
  const next = queue.then(task, task);
  queue = next.catch(() => undefined);
  return next;
}

/** Plain-text status line for the transcript, used in every tool result. */
export function describeTranscript(result: TranscriptResult): string {
  switch (result.kind) {
    case "ok":
      return `Speech: ${result.segments.length} segment(s), language ${result.language ?? "unknown"}, transcribed ${result.label}.`;
    case "no-speech":
      return `Speech: none detected (transcribed ${result.label}).`;
    case "no-audio":
      return "Speech: the file has no audio track.";
    case "skipped":
      return `Speech: not transcribed (${result.reason}).`;
    case "pending":
      return `Speech: ${result.message}`;
    case "unavailable":
      return `Speech: unavailable. ${result.message}`;
  }
}

/** Transcript lines within [start, end], one per segment. */
export function transcriptLines(result: TranscriptResult, range: { start: number; end: number }, withHours: boolean): string[] {
  if (result.kind !== "ok") return [];
  return result.segments
    .filter((s) => s.end >= range.start && s.start <= range.end)
    .map((s) => `${formatTime(s.start, 1, withHours)}-${formatTime(s.end, 1, withHours)}  "${s.text}"`);
}

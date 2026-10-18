import { WatchError } from "./errors.ts";
import { updateTimeline, type BundleSpeech } from "./bundle.ts";
import { describeTranscript } from "./transcribe.ts";
import { watchCore, type ProgressFn } from "./watch.ts";

export interface FinalizeSummary {
  status: string;
  message: string;
  language: string | null;
  duration: number;
  /** Everything that was said, as one string (for the recorder's prompt). */
  text: string;
  keyframes: number;
}

/**
 * Completes a recording bundle: transcribes it (word timestamps included), picks the default
 * keyframes, and writes both into timeline.json. Also warms the cache, so the first
 * watch_video / latest_recording call on it is instant.
 */
export async function finalizeBundle(dir: string, onProgress?: ProgressFn): Promise<FinalizeSummary> {
  const core = await watchCore({ path: dir, waitForModel: true, onProgress });
  const bundle = core.loaded.bundle;
  if (!bundle) throw new WatchError("BAD_ARGUMENT", "finalize expects a .watch recording bundle folder.");
  const t = core.transcript;
  let speech: BundleSpeech | undefined;
  if (t.kind === "ok") speech = { source: t.source, language: t.language, segments: t.segments, words: t.words };
  else if (t.kind === "no-speech") speech = { source: t.source, language: null, segments: [], words: [] };
  const keyframes = core.visual.frames.map((f) => ({ t: f.t, change: Math.round(f.change * 1000) / 1000, cut: f.cut }));
  updateTimeline(bundle.dir, speech ? { speech, keyframes } : { keyframes });
  return {
    status: t.kind,
    message: describeTranscript(t),
    language: t.kind === "ok" ? t.language : null,
    duration: core.loaded.info.duration,
    text: t.kind === "ok" ? t.segments.map((s) => s.text).join(" ") : "",
    keyframes: keyframes.length,
  };
}

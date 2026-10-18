import type { VideoInfo } from "../probe.ts";
import type { TimedText } from "../words.ts";

export type { TimedText };

/** What a backend returns. Empty `segments` means no speech. Times are seconds on the video clock. */
export interface RawTranscript {
  language: string | null;
  /** Readable chunks (sentences or so). */
  segments: TimedText[];
  /** Word-level timings; may be empty when a backend cannot provide them. */
  words: TimedText[];
}

export interface BackendJob {
  info: VideoInfo;
  /** ISO 639-1 code, or "auto". */
  language: string;
  signal?: AbortSignal | undefined;
  onProgress?: ((message: string, fraction: number) => void) | undefined;
}

export type Availability =
  | { ready: true }
  /** canPrepare: prepare() can fix it (e.g. a model download); otherwise the message says what the user must do. */
  | { ready: false; message: string; canPrepare: boolean };

/**
 * A speech-to-text engine. Local Whisper is the default; a cloud engine (OpenAI, Deepgram,
 * Wispr Flow with an enterprise key...) can be added by implementing this and registering
 * it in ./index.ts. Backends must return timestamps on the video clock: watch_video lines
 * speech up with frames, so a backend without timestamps cannot be used.
 */
export interface TranscriptionBackend {
  /** Stable id, part of cache keys: "whisper-local:large-v3-turbo-q5_0". */
  readonly id: string;
  /** Shown to the user: "locally with Whisper large-v3-turbo-q5_0". */
  readonly label: string;
  /** Must not block or touch the network. */
  availability(): Availability;
  /** Gets the backend ready (downloads, checks); progress goes from 0 to 1. Safe to call concurrently. */
  prepare(onProgress?: (message: string, fraction: number) => void): Promise<void>;
  transcribe(job: BackendJob): Promise<RawTranscript>;
}

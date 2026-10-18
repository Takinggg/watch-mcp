import { fork } from "node:child_process";
import { fileURLToPath } from "node:url";
import { getBinaries } from "../binaries.ts";
import { WatchError } from "../errors.ts";
import { downloadState, ensureModel, isInstalled, modelPath, VAD_MODEL, WHISPER_MODELS, type ModelSpec } from "../models.ts";
import type { TimedText } from "../words.ts";
import type { Availability, BackendJob, RawTranscript, TranscriptionBackend } from "./backend.ts";
import type { WorkerMessage, WorkerRequest } from "./whisper-worker.ts";

/** Whisper text must overlap detected speech by this margin (s), which drops text invented over silence. */
const SPEECH_PAD = 0.3;

export function whisperModel(): ModelSpec {
  const requested = process.env.WATCH_MCP_WHISPER_MODEL?.trim();
  if (requested) {
    const spec = WHISPER_MODELS[requested];
    if (!spec) {
      throw new WatchError("MODEL", `Unknown WATCH_MCP_WHISPER_MODEL "${requested}". Use one of: ${Object.keys(WHISPER_MODELS).join(", ")}.`);
    }
    return spec;
  }
  // Apple Silicon runs the large turbo model on Metal in about 1 s per 30 s of speech; elsewhere default to the small CPU-friendly one.
  const metal = process.platform === "darwin" && process.arch === "arm64";
  return (metal ? WHISPER_MODELS["large-v3-turbo-q5_0"] : WHISPER_MODELS.base) as ModelSpec;
}

/** whisper.cpp on this machine (Metal on Apple Silicon), with Silero VAD, in a child process. */
export class WhisperLocalBackend implements TranscriptionBackend {
  readonly id: string;
  readonly label: string;
  private readonly spec: ModelSpec;

  constructor(spec: ModelSpec = whisperModel()) {
    this.spec = spec;
    this.id = `whisper-local:${spec.id}`;
    this.label = `locally with Whisper ${spec.id}`;
  }

  availability(): Availability {
    if (isInstalled(this.spec) && isInstalled(VAD_MODEL)) return { ready: true };
    const state = downloadState(this.spec);
    if (state?.error) return { ready: false, canPrepare: true, message: `Speech model download failed: ${state.error} Call the transcribe tool to retry.` };
    const pct = state && state.total > 0 ? ` (${Math.floor((state.received / state.total) * 100)}% done)` : "";
    return {
      ready: false,
      canPrepare: true,
      message: `Speech model ${this.spec.file} (${Math.round(this.spec.sizeBytes / 1e6)} MB, one-time download) is downloading${pct}. Call the transcribe tool with the same path in about a minute to get the transcript without re-sending the images.`,
    };
  }

  async prepare(onProgress?: (message: string, fraction: number) => void): Promise<void> {
    await ensureModel(VAD_MODEL);
    await ensureModel(this.spec, (received, total) => onProgress?.(`Downloading speech model ${this.spec.file}`, received / total));
  }

  async transcribe(job: BackendJob): Promise<RawTranscript> {
    const request: WorkerRequest = {
      ffmpeg: getBinaries().ffmpeg,
      file: job.info.path,
      whisperModel: modelPath(this.spec),
      vadModel: modelPath(VAD_MODEL),
      language: job.language,
      useGpu: process.env.WATCH_MCP_WHISPER_GPU !== "0",
    };
    const timeoutMs = 120_000 + job.info.duration * 1000;
    const result = await runWorker(request, { timeoutMs, signal: job.signal, onProgress: job.onProgress });
    return {
      language: result.language,
      segments: keepSpoken(result.segments, result.speech),
      words: keepSpoken(result.words, result.speech),
    };
  }
}

/** Drops empty text and pieces that do not overlap any detected speech. */
export function keepSpoken(pieces: readonly TimedText[], speech: ReadonlyArray<readonly [number, number]>): TimedText[] {
  return pieces.filter((piece) => {
    if (piece.text.trim().length === 0) return false;
    return speech.some(([s, e]) => piece.start < e + SPEECH_PAD && piece.end > s - SPEECH_PAD);
  });
}

type WorkerResult = Extract<WorkerMessage, { type: "result" }>;

function workerPath(): string {
  const ext = import.meta.url.endsWith(".ts") ? ".ts" : ".js";
  return fileURLToPath(new URL(`./whisper-worker${ext}`, import.meta.url));
}

interface WorkerOptions {
  timeoutMs: number;
  signal?: AbortSignal | undefined;
  onProgress?: ((message: string, fraction: number) => void) | undefined;
}

function runWorker(request: WorkerRequest, opts: WorkerOptions): Promise<WorkerResult> {
  return new Promise((resolve, reject) => {
    // stdout is ignored: the MCP protocol owns this process's stdout.
    const child = fork(workerPath(), [], { stdio: ["ignore", "ignore", "pipe", "ipc"], execArgv: [] });
    let settled = false;
    let stderr = "";
    const finish = (err: WatchError | null, value?: WorkerResult): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      opts.signal?.removeEventListener("abort", onAbort);
      if (child.exitCode === null) child.kill("SIGKILL");
      if (err) reject(err);
      else resolve(value as WorkerResult);
    };
    const timer = setTimeout(() => finish(new WatchError("TIMEOUT", "Transcription took too long and was stopped.")), opts.timeoutMs);
    const onAbort = (): void => finish(new WatchError("CANCELLED", "The request was cancelled."));
    opts.signal?.addEventListener("abort", onAbort, { once: true });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-4000);
    });
    child.on("message", (msg: WorkerMessage) => {
      if (msg.type === "progress") opts.onProgress?.(progressLabel(msg.stage), 0.5 + 0.5 * stageFraction(msg.stage, msg.fraction));
      else if (msg.type === "result") finish(null, msg);
      else finish(new WatchError("TRANSCRIBE", `Transcription failed: ${msg.message}`));
    });
    child.on("error", () => finish(new WatchError("TRANSCRIBE", "Could not start the transcription process.")));
    // "close" (not "exit") fires after the IPC channel is drained, so a final result message is never lost.
    child.on("close", (code, signal) => {
      const detail = signal ? `signal ${signal}` : `exit code ${String(code)}`;
      finish(new WatchError("TRANSCRIBE", `The transcription process stopped unexpectedly (${detail}).${nativeHint(stderr)}`));
    });
    child.send(request);
  });
}

function nativeHint(stderr: string): string {
  return /ggml_abort|GGML_ASSERT/.test(stderr) ? " Try WATCH_MCP_WHISPER_GPU=0 to run Whisper on the CPU." : "";
}

function progressLabel(stage: "audio" | "vad" | "whisper"): string {
  if (stage === "audio") return "Extracting audio";
  if (stage === "vad") return "Detecting speech";
  return "Transcribing speech";
}

function stageFraction(stage: "audio" | "vad" | "whisper", fraction: number): number {
  if (stage === "audio") return 0;
  if (stage === "vad") return 0.1;
  return 0.15 + 0.85 * Math.min(1, Math.max(0, fraction));
}

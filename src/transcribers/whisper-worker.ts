/**
 * Child process that runs voice activity detection + Whisper on one file.
 * It is separate from the MCP server so a native crash cannot take the server down.
 *
 * Input (IPC): WorkerRequest. Output (IPC): WorkerMessage.
 */
import { spawn } from "node:child_process";
import { packSpeech, SAMPLE_RATE, toOriginalTime } from "../speech-pack.ts";
import { tokensToWords, wordsToSegments, type TimedText } from "../words.ts";

export interface WorkerRequest {
  ffmpeg: string;
  file: string;
  whisperModel: string;
  vadModel: string;
  language: string;
  useGpu: boolean;
}

export type WorkerMessage =
  | { type: "progress"; stage: "audio" | "vad" | "whisper"; fraction: number }
  | { type: "result"; language: string | null; speech: Array<[number, number]>; segments: TimedText[]; words: TimedText[] }
  | { type: "error"; message: string };

const MAX_AUDIO_SECONDS = 4 * 3600;

function send(message: WorkerMessage): void {
  process.send?.(message);
}

function extractPcm(req: WorkerRequest): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const child = spawn(req.ffmpeg, [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-i", `file:${req.file}`, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", String(SAMPLE_RATE),
      "-t", String(MAX_AUDIO_SECONDS), "-f", "s16le", "pipe:1",
    ], { stdio: ["ignore", "pipe", "pipe"] });
    const chunks: Buffer[] = [];
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-2000);
    });
    child.on("error", () => reject(new Error("ffmpeg could not start")));
    child.on("close", (code) => {
      if (code === 0) resolve(Buffer.concat(chunks));
      else reject(new Error(`ffmpeg could not read the audio track (${stderr.trim().split("\n").pop() ?? "no details"})`));
    });
  });
}

/** The subset of @fugood/whisper.node used here (the package ships .ts sources instead of .d.ts files). */
interface WhisperBinding {
  initWhisperVad(options: { filePath: string; useGpu: boolean; nThreads: number }): Promise<{
    detectSpeechData(audio: ArrayBuffer): Promise<Array<{ t0: number; t1: number }>>;
    release(): Promise<void>;
  }>;
  initWhisper(options: { filePath: string; useGpu: boolean }): Promise<{
    transcribeData(
      audio: ArrayBuffer,
      options: { language: string; temperature: number; tokenTimestamps: boolean; maxLen: number; onProgress: (progress: number) => void },
    ): { promise: Promise<{ language?: string; segments: Array<{ text: string; t0: number; t1: number }> }> };
    release(): Promise<void>;
  }>;
}

const BINDING = "@fugood/whisper.node";

function toArrayBuffer(buffer: Buffer): ArrayBuffer {
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) as ArrayBuffer;
}

async function main(req: WorkerRequest): Promise<void> {
  // Imported here so a missing native build is reported as an error message, not a crash at load.
  // The specifier is a variable so TypeScript does not type-check the package's bundled .ts sources.
  const whisper = (await import(BINDING)) as WhisperBinding;
  send({ type: "progress", stage: "audio", fraction: 0 });
  const pcm = await extractPcm(req);
  const audioSeconds = pcm.length / 2 / SAMPLE_RATE;

  send({ type: "progress", stage: "vad", fraction: 0 });
  // Silero VAD aborts on the Metal backend in this build, so it always runs on the CPU (it is tiny).
  const vad = await whisper.initWhisperVad({ filePath: req.vadModel, useGpu: false, nThreads: 4 });
  const speechCs = await vad.detectSpeechData(toArrayBuffer(pcm));
  await vad.release();
  // VAD timestamps are in centiseconds.
  const speech = speechCs.map((s): [number, number] => [s.t0 / 100, s.t1 / 100]);
  if (speech.length === 0) {
    send({ type: "result", language: null, speech, segments: [], words: [] });
    return;
  }

  send({ type: "progress", stage: "whisper", fraction: 0 });
  // Whisper only hears the speech (silences removed), which keeps its timestamps accurate
  // and stops it from inventing words over long quiet stretches. Times are mapped back after.
  const packed = packSpeech(pcm, speech, audioSeconds);
  const ctx = await whisper.initWhisper({ filePath: req.whisperModel, useGpu: req.useGpu });
  // Token timestamps with a 1-character max segment length make whisper.cpp emit one piece per token,
  // in the same single pass: those pieces become words, then readable segments.
  const job = ctx.transcribeData(toArrayBuffer(packed.audio), {
    language: req.language,
    temperature: 0,
    tokenTimestamps: true,
    maxLen: 1,
    onProgress: (p: number) => send({ type: "progress", stage: "whisper", fraction: p / 100 }),
  });
  const result = await job.promise;
  await ctx.release();
  // Whisper timestamps are in milliseconds of the packed audio.
  const tokens = result.segments.map((seg) => ({
    start: roundMs(toOriginalTime(packed.pieces, seg.t0 / 1000)),
    end: roundMs(toOriginalTime(packed.pieces, seg.t1 / 1000)),
    text: seg.text,
  }));
  const words = tokensToWords(tokens);
  send({ type: "result", language: result.language ?? null, speech, segments: wordsToSegments(words), words });
}

function roundMs(seconds: number): number {
  return Math.round(seconds * 1000) / 1000;
}

process.once("message", (req: WorkerRequest) => {
  main(req)
    .catch((err: unknown) => send({ type: "error", message: err instanceof Error ? err.message : "transcription failed" }))
    .finally(() => process.disconnect?.());
});

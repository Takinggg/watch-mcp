import { getBinaries } from "./binaries.ts";
import { run } from "./exec.ts";
import type { VideoInfo } from "./probe.ts";

export interface Signatures {
  /** Seconds from the start of the video, one per signature. */
  times: number[];
  sigs: Uint8Array[];
  width: number;
  height: number;
  fps: number;
}

export interface AnalyzeOptions {
  start: number;
  end: number;
  signal?: AbortSignal | undefined;
  onProgress?: ((done: number, total: number) => void) | undefined;
}

/** Upper bound on analysis samples, so memory and time stay flat for long videos. */
const MAX_SAMPLES = 2400;
const MAX_ANALYSIS_FPS = 8;
const SIG_LONG_EDGE = 128;

export function analysisFps(info: VideoInfo, span: number): number {
  const byBudget = MAX_SAMPLES / Math.max(span, 0.001);
  return Math.max(0.05, Math.min(MAX_ANALYSIS_FPS, info.fps, byBudget));
}

export function signatureSize(info: VideoInfo): { width: number; height: number } {
  const landscape = info.width >= info.height;
  const long = SIG_LONG_EDGE;
  const short = Math.max(8, Math.round((long * Math.min(info.width, info.height)) / Math.max(info.width, info.height) / 2) * 2);
  return landscape ? { width: long, height: short } : { width: short, height: long };
}

/**
 * Decodes the range once at a low frame rate into tiny grayscale frames
 * (128 px on the long edge). These signatures drive keyframe selection.
 */
export async function computeSignatures(info: VideoInfo, opts: AnalyzeOptions): Promise<Signatures> {
  const { ffmpeg } = getBinaries();
  const span = Math.max(0.001, opts.end - opts.start);
  const fps = analysisFps(info, span);
  const { width, height } = signatureSize(info);
  const frameBytes = width * height;
  const expected = Math.max(1, Math.ceil(span * fps));
  const sigs: Uint8Array[] = [];
  let current = new Uint8Array(frameBytes);
  let filled = 0;

  const onStdout = (chunk: Buffer): void => {
    let offset = 0;
    while (offset < chunk.length) {
      const take = Math.min(frameBytes - filled, chunk.length - offset);
      current.set(chunk.subarray(offset, offset + take), filled);
      filled += take;
      offset += take;
      if (filled === frameBytes) {
        sigs.push(current);
        current = new Uint8Array(frameBytes);
        filled = 0;
        if (sigs.length % 50 === 0) opts.onProgress?.(sigs.length, expected);
      }
    }
  };

  await run(ffmpeg, {
    label: "ffmpeg",
    args: [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      // Skipping the deblocking filter speeds decoding up ~35% and does not matter at 128 px.
      "-skip_loop_filter", "all", "-flags2", "fast",
      "-ss", opts.start.toFixed(3), "-i", `file:${info.path}`, "-t", span.toFixed(3),
      "-map", "0:v:0", "-an", "-sn", "-dn",
      "-vf", `fps=${fps.toFixed(6)},scale=${width}:${height}:flags=area,format=gray`,
      "-f", "rawvideo", "pipe:1",
    ],
    timeoutMs: 120_000 + span * 2000,
    signal: opts.signal,
    maxStdoutBytes: frameBytes * (MAX_SAMPLES * 2 + 16),
    onStdout,
  });
  const times = sigs.map((_, k) => Math.min(opts.end, opts.start + k / fps));
  return { times, sigs, width, height, fps };
}

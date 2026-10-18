import { describeTranscript, getTranscript, transcriptLines } from "./transcribe.ts";
import { loadVideo, type ProgressFn, type ToolOutput } from "./watch.ts";

export interface TranscribeParams {
  path: string;
  language?: string | undefined;
  signal?: AbortSignal | undefined;
  onProgress?: ProgressFn | undefined;
}

/** Text-only transcript; waits for the speech model if it is still downloading. */
export async function transcribeTool(params: TranscribeParams): Promise<ToolOutput> {
  const { info, fp } = await loadVideo(params.path, params.signal);
  const result = await getTranscript(info, fp, {
    language: params.language,
    signal: params.signal,
    waitForModel: true,
    onProgress: params.onProgress,
  });
  const lines = transcriptLines(result, { start: 0, end: info.duration }, info.duration >= 3600);
  const intro = [`TRANSCRIPT ${info.name}`, describeTranscript(result), ...lines].join("\n");
  return { intro, images: [], outro: "" };
}

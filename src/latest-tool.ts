import { existsSync } from "node:fs";
import { WatchError } from "./errors.ts";
import { ago, readLatestRecording } from "./recordings.ts";
import { formatTime } from "./time.ts";
import { watchVideo, type ProgressFn, type ToolOutput } from "./watch.ts";

export interface LatestParams {
  budget?: number | undefined;
  signal?: AbortSignal | undefined;
  onProgress?: ProgressFn | undefined;
}

/** watch_video on the most recent WatchRecorder recording, with a header saying what it is. */
export async function latestRecordingTool(params: LatestParams): Promise<ToolOutput> {
  const latest = readLatestRecording();
  if (!latest) {
    throw new WatchError(
      "NOT_FOUND",
      "No recording yet. Record your screen and voice with the WatchRecorder menu-bar app (macOS companion, see the watch-mcp README), then call this again.",
    );
  }
  if (!existsSync(latest.path)) {
    throw new WatchError("NOT_FOUND", `The latest recording is no longer at ${latest.path} (moved or deleted).`);
  }
  const out = await watchVideo({ path: latest.path, budget: params.budget, signal: params.signal, onProgress: params.onProgress });
  const header = [
    `LATEST RECORDING of the user's screen, made ${ago(latest.startedAt)}, ${formatTime(latest.duration)} long: ${latest.path}`,
    "The user recorded this to show you something. Their spoken request is in the speech lines of the timeline; do what they asked.",
  ].join("\n");
  return { ...out, intro: `${header}\n\n${out.intro}` };
}

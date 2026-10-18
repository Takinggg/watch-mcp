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

/**
 * Text of the "latest" MCP prompt: in Claude Code it is the /mcp__watch__latest command, which
 * puts the latest recording into the current conversation without any copy and paste.
 */
export function latestPromptText(): string {
  const latest = readLatestRecording();
  if (!latest) {
    return "I have not recorded anything with WatchRecorder yet. Tell me how to record my screen and voice for you.";
  }
  const said = latest.transcript === null ? "(not transcribed)" : latest.transcript.length === 0 ? "(no speech detected)" : `"${latest.transcript}"`;
  return [
    "Watch my latest screen recording and do what I ask in it.",
    "",
    `Recording: ${latest.path} (${formatTime(latest.duration)}, made ${ago(latest.startedAt)})`,
    `What I said: ${said}`,
    "",
    "Call the latest_recording tool to see what I showed on screen.",
  ].join("\n");
}

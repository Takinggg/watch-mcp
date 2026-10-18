import { WatchError } from "../errors.ts";
import type { TranscriptionBackend } from "./backend.ts";
import { WhisperLocalBackend } from "./whisper-local.ts";

/**
 * Available speech-to-text backends, chosen with WATCH_MCP_TRANSCRIBER.
 * To add one (a cloud API with word timestamps, for example): implement
 * TranscriptionBackend in a new file and add a line here.
 */
const BACKENDS: Record<string, () => TranscriptionBackend> = {
  "whisper-local": () => new WhisperLocalBackend(),
};

export const DEFAULT_BACKEND = "whisper-local";

export function backendNames(): string[] {
  return Object.keys(BACKENDS);
}

export function selectBackend(): TranscriptionBackend {
  const name = process.env.WATCH_MCP_TRANSCRIBER?.trim() || DEFAULT_BACKEND;
  const make = BACKENDS[name];
  if (!make) {
    throw new WatchError("MODEL", `Unknown WATCH_MCP_TRANSCRIBER "${name}". Available: ${backendNames().join(", ")}.`);
  }
  return make();
}

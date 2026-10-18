export type WatchErrorCode =
  | "BAD_ARGUMENT"
  | "NOT_FOUND"
  | "UNSUPPORTED"
  | "NO_VIDEO"
  | "FFMPEG_MISSING"
  | "FFMPEG_FAILED"
  | "TIMEOUT"
  | "CANCELLED"
  | "MODEL"
  | "TRANSCRIBE";

/** An error whose message is meant to be read by the user (and by Claude). */
export class WatchError extends Error {
  readonly code: WatchErrorCode;

  constructor(code: WatchErrorCode, message: string) {
    super(message);
    this.name = "WatchError";
    this.code = code;
  }
}

/** Turns any thrown value into a short message that is safe to show. */
export function describeError(err: unknown): string {
  if (err instanceof WatchError) return err.message;
  if (err instanceof Error && err.name === "AbortError") return "The request was cancelled.";
  // Unknown errors can carry stack traces or internal paths: keep only a generic line.
  return "Unexpected internal error in watch-mcp. Run `npx watch-mcp doctor` to check the setup.";
}

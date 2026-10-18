import { spawn } from "node:child_process";
import { WatchError } from "./errors.ts";

export interface RunOptions {
  args: readonly string[];
  timeoutMs: number;
  signal?: AbortSignal | undefined;
  /** Written to the child's stdin, which is then closed. */
  input?: Buffer | undefined;
  /** Upper bound on buffered stdout; the child is killed beyond it. */
  maxStdoutBytes?: number | undefined;
  /** Streams stdout instead of buffering it. */
  onStdout?: ((chunk: Buffer) => void) | undefined;
  /** Short name used in error messages ("ffmpeg", "ffprobe"). */
  label: string;
}

export interface RunResult {
  stdout: Buffer;
  stderr: string;
}

const STDERR_KEEP = 8192;
const DEFAULT_MAX_STDOUT = 512 * 1024 * 1024;

/**
 * Runs a binary with a hard timeout, cancellation and bounded output.
 * Rejects with a WatchError; the message keeps only the last stderr lines.
 */
export function run(bin: string, opts: RunOptions): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    if (opts.signal?.aborted) {
      reject(new WatchError("CANCELLED", "The request was cancelled."));
      return;
    }
    const child = spawn(bin, [...opts.args], {
      stdio: [opts.input ? "pipe" : "ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const chunks: Buffer[] = [];
    const maxStdout = opts.maxStdoutBytes ?? DEFAULT_MAX_STDOUT;
    let stdoutBytes = 0;
    let stderr = "";
    let failure: WatchError | null = null;

    const stop = (err: WatchError): void => {
      if (failure) return;
      failure = err;
      child.kill("SIGKILL");
    };
    const timer = setTimeout(() => {
      stop(new WatchError("TIMEOUT", `${opts.label} took longer than ${Math.round(opts.timeoutMs / 1000)} s and was stopped.`));
    }, opts.timeoutMs);
    const onAbort = (): void => stop(new WatchError("CANCELLED", "The request was cancelled."));
    opts.signal?.addEventListener("abort", onAbort, { once: true });

    child.stdout?.on("data", (chunk: Buffer) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > maxStdout) {
        stop(new WatchError("FFMPEG_FAILED", `${opts.label} produced more output than expected and was stopped.`));
        return;
      }
      if (opts.onStdout) opts.onStdout(chunk);
      else chunks.push(chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-STDERR_KEEP);
    });
    if (opts.input && child.stdin) {
      // The child may exit before reading everything (EPIPE): the exit code reports the real problem.
      child.stdin.on("error", () => undefined);
      child.stdin.end(opts.input);
    }
    child.on("error", (err: NodeJS.ErrnoException) => {
      const missing = err.code === "ENOENT";
      stop(new WatchError(missing ? "FFMPEG_MISSING" : "FFMPEG_FAILED", missing ? `${opts.label} binary not found.` : `${opts.label} could not start.`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      opts.signal?.removeEventListener("abort", onAbort);
      if (failure) reject(failure);
      else if (code !== 0) reject(new WatchError("FFMPEG_FAILED", `${opts.label} failed: ${lastLines(stderr)}`));
      else resolve({ stdout: Buffer.concat(chunks), stderr });
    });
  });
}

/** Keeps the last few meaningful stderr lines, which is where ffmpeg explains failures. */
export function lastLines(stderr: string, count = 3): string {
  const lines = stderr
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const tail = lines.slice(-count).join(" | ");
  return tail.length > 0 ? tail.slice(0, 600) : "no error output";
}

/** Runs async tasks with at most `limit` in flight, preserving result order. */
export async function mapLimit<T, R>(items: readonly T[], limit: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await fn(items[index] as T, index);
    }
  });
  await Promise.all(workers);
  return results;
}

import { createHash } from "node:crypto";
import { createWriteStream, existsSync, renameSync, statSync, unlinkSync } from "node:fs";
import path from "node:path";
import { modelsDir } from "./cache.ts";
import { WatchError } from "./errors.ts";

export interface ModelSpec {
  id: string;
  file: string;
  url: string;
  sizeBytes: number;
  /** SHA-256 published by Hugging Face (LFS object id); the download is rejected if it differs. */
  sha256: string;
  note: string;
}

const WHISPER_REPO = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

export const WHISPER_MODELS: Record<string, ModelSpec> = {
  base: {
    id: "base",
    file: "ggml-base.bin",
    url: `${WHISPER_REPO}/ggml-base.bin`,
    sizeBytes: 147_951_465,
    sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    note: "multilingual, fastest, lower accuracy",
  },
  small: {
    id: "small",
    file: "ggml-small.bin",
    url: `${WHISPER_REPO}/ggml-small.bin`,
    sizeBytes: 487_601_967,
    sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    note: "multilingual, balanced",
  },
  "large-v3-turbo-q5_0": {
    id: "large-v3-turbo-q5_0",
    file: "ggml-large-v3-turbo-q5_0.bin",
    url: `${WHISPER_REPO}/ggml-large-v3-turbo-q5_0.bin`,
    sizeBytes: 574_041_195,
    sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    note: "multilingual, most accurate of the three; best with a GPU (Metal on Apple Silicon)",
  },
};

export const VAD_MODEL: ModelSpec = {
  id: "silero-v6.2.0",
  file: "ggml-silero-v6.2.0.bin",
  url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
  sizeBytes: 885_098,
  sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
  note: "voice activity detection, skips silence so Whisper does not invent words",
};

export function modelPath(spec: ModelSpec): string {
  return path.join(modelsDir(), spec.file);
}

/** Installed means present with the expected size (the hash was checked when it was downloaded). */
export function isInstalled(spec: ModelSpec): boolean {
  const file = modelPath(spec);
  return existsSync(file) && statSync(file).size === spec.sizeBytes;
}

export interface DownloadState {
  received: number;
  total: number;
  error: string | null;
  promise: Promise<string> | null;
}

const states = new Map<string, DownloadState>();

export function downloadState(spec: ModelSpec): DownloadState | null {
  return states.get(spec.id) ?? null;
}

/**
 * Downloads a model once per process (concurrent callers share the same download),
 * verifying size and SHA-256 before moving it into place.
 */
export function ensureModel(spec: ModelSpec, onProgress?: (received: number, total: number) => void): Promise<string> {
  if (isInstalled(spec)) return Promise.resolve(modelPath(spec));
  const existing = states.get(spec.id);
  if (existing?.promise) return existing.promise;
  const state: DownloadState = { received: 0, total: spec.sizeBytes, error: null, promise: null };
  states.set(spec.id, state);
  process.stderr.write(`[watch-mcp] Downloading ${spec.file} (${Math.round(spec.sizeBytes / 1e6)} MB, one time) to ${modelsDir()}\n`);
  state.promise = download(spec, (received) => {
    state.received = received;
    onProgress?.(received, spec.sizeBytes);
  })
    .then((file) => {
      process.stderr.write(`[watch-mcp] ${spec.file} ready.\n`);
      states.delete(spec.id);
      return file;
    })
    .catch((err: unknown) => {
      state.error = err instanceof WatchError ? err.message : "download failed";
      state.promise = null;
      throw err;
    });
  return state.promise;
}

const STALL_MS = 60_000;

async function download(spec: ModelSpec, onBytes: (received: number) => void): Promise<string> {
  const target = modelPath(spec);
  const partial = `${target}.part`;
  const controller = new AbortController();
  let stallTimer = setTimeout(() => controller.abort(), STALL_MS);
  try {
    const response = await fetch(spec.url, { signal: controller.signal, redirect: "follow" });
    if (!response.ok || !response.body) throw new WatchError("MODEL", `Model download failed (HTTP ${response.status}).`);
    const hash = createHash("sha256");
    const out = createWriteStream(partial);
    let received = 0;
    for await (const chunk of response.body as AsyncIterable<Uint8Array>) {
      clearTimeout(stallTimer);
      stallTimer = setTimeout(() => controller.abort(), STALL_MS);
      received += chunk.length;
      if (received > spec.sizeBytes) throw new WatchError("MODEL", "Model download is larger than expected; aborted.");
      hash.update(chunk);
      if (!out.write(chunk)) await new Promise((resolve) => out.once("drain", resolve));
      onBytes(received);
    }
    await new Promise<void>((resolve, reject) => out.end((err?: Error | null) => (err ? reject(err) : resolve())));
    if (received !== spec.sizeBytes || hash.digest("hex") !== spec.sha256) {
      throw new WatchError("MODEL", `Downloaded ${spec.file} does not match its published checksum; it was discarded.`);
    }
    renameSync(partial, target);
    return target;
  } catch (err) {
    removeQuietly(partial);
    if (err instanceof WatchError) throw err;
    throw new WatchError("MODEL", `Could not download ${spec.file} from huggingface.co (network error or stalled for 60 s).`);
  } finally {
    clearTimeout(stallTimer);
  }
}

function removeQuietly(file: string): void {
  try {
    unlinkSync(file);
  } catch {
    // Nothing to clean up.
  }
}

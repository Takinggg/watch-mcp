import { getBinaries } from "./binaries.ts";
import { run } from "./exec.ts";
import type { Canvas } from "./font.ts";

export type JpegProfile = "sheet" | "detail";

/**
 * Encodes an RGB24 canvas to JPEG with ffmpeg (no image library needed).
 * "detail" keeps full chroma (4:4:4) and a higher quality, for reading small text.
 */
export async function encodeJpeg(canvas: Canvas, profile: JpegProfile, signal?: AbortSignal): Promise<Buffer> {
  const { ffmpeg } = getBinaries();
  const detail = profile === "detail";
  const { stdout } = await run(ffmpeg, {
    label: "ffmpeg",
    args: [
      "-hide_banner", "-loglevel", "error", "-nostdin",
      "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", `${canvas.width}x${canvas.height}`, "-i", "pipe:0",
      "-frames:v", "1", "-c:v", "mjpeg",
      "-q:v", detail ? "2" : "3",
      "-pix_fmt", detail ? "yuvj444p" : "yuvj420p",
      "-f", "image2pipe", "pipe:1",
    ],
    input: canvas.data,
    timeoutMs: 30_000,
    signal,
    maxStdoutBytes: 16 * 1024 * 1024,
  });
  return stdout;
}

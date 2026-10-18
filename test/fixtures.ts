import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getBinaries } from "../src/binaries.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
export const FIXTURES = path.join(here, ".fixtures");

/** Isolated result cache per test process; models stay in the shared folder. */
process.env.WATCH_MCP_CACHE_DIR ??= mkdtempSync(path.join(os.tmpdir(), "watch-mcp-test-"));

export const hasSay = process.platform === "darwin" && spawnSync("say", ["-v", "?"]).status === 0;

function ffmpeg(args: string[]): void {
  execFileSync(getBinaries().ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", ...args]);
}

/** Speaks English text to an AIFF file with the first available English voice. */
function speak(text: string, out: string): void {
  for (const voice of ["Samantha", "Daniel", "Alex", "Fred"]) {
    if (spawnSync("say", ["-v", voice, "-o", out, text]).status === 0) return;
  }
  execFileSync("say", ["-o", out, text]);
}

/**
 * slides.mp4, 20 s, 640x360 @ 25 fps, with known structure:
 *   0-4 s  static SMPTE bars      4-8 s  static red
 *   8-12 s moving test pattern    12-20 s static RGB test pattern
 * Audio: a spoken English sentence at 13 s when macOS `say` exists, else a 440 Hz tone.
 */
export function slidesVideo(): string {
  const out = path.join(FIXTURES, "slides.mp4");
  if (existsSync(out)) return out;
  mkdirSync(FIXTURES, { recursive: true });
  const video =
    "smptebars=s=640x360:r=25:d=4[a];color=c=red:s=640x360:r=25:d=4[b];" +
    "testsrc2=s=640x360:r=25:d=4[c];rgbtestsrc=s=640x360:r=25:d=8[d];" +
    "[a][b][c][d]concat=n=4:v=1:a=0,format=yuv420p[v]";
  let audioInput: string[];
  let audioFilter: string;
  if (hasSay) {
    const speech = path.join(FIXTURES, "speech.aiff");
    speak("The export button is broken. Please fix the dialog.", speech);
    audioInput = ["-i", speech];
    audioFilter = "[0:a]adelay=13000|13000,apad,atrim=0:20[aout]";
  } else {
    audioInput = ["-f", "lavfi", "-i", "sine=frequency=440:duration=20"];
    audioFilter = "[0:a]anull[aout]";
  }
  ffmpeg([...audioInput, "-filter_complex", `${video};${audioFilter}`, "-map", "[v]", "-map", "[aout]", "-t", "20", "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", out]);
  return out;
}

/** clip.<ext>: 3 s moving pattern, no audio, in the given container (mov, mkv, webm). */
export function shortClip(ext: "mov" | "mkv" | "webm", size = "320x180"): string {
  const out = path.join(FIXTURES, `clip-${size}.${ext}`);
  if (existsSync(out)) return out;
  mkdirSync(FIXTURES, { recursive: true });
  const codec = ext === "webm" ? ["-c:v", "libvpx-vp9", "-b:v", "300k", "-deadline", "realtime"] : ["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p"];
  ffmpeg(["-f", "lavfi", "-i", `testsrc2=s=${size}:r=25:d=3`, ...codec, out]);
  return out;
}

/** Width and height read from a JPEG's start-of-frame marker. */
export function jpegSize(data: Buffer): { width: number; height: number } {
  if (data[0] !== 0xff || data[1] !== 0xd8) throw new Error("not a JPEG");
  let offset = 2;
  while (offset + 9 < data.length) {
    if (data[offset] !== 0xff) throw new Error("bad JPEG marker");
    const marker = data[offset + 1] as number;
    const length = data.readUInt16BE(offset + 2);
    if (marker >= 0xc0 && marker <= 0xc3) return { height: data.readUInt16BE(offset + 5), width: data.readUInt16BE(offset + 7) };
    offset += 2 + length;
  }
  throw new Error("JPEG has no SOF marker");
}

/** Parses the "mm:ss.s  SEEN #n" timeline rows into frame times. */
export function frameTimes(timeline: string): number[] {
  return [...timeline.matchAll(/^(\d\d):(\d\d\.\d)  SEEN #\d+ /gm)].map((m) => Number(m[1]) * 60 + Number(m[2]));
}

/** A bundle around slides.mp4 (20 s, static red from 4 to 8 s) with the given timeline. */
export function makeBundle(timeline: unknown, manifest: Record<string, unknown> = {}): string {
  const slides = slidesVideo();
  const dir = path.join(mkdtempSync(path.join(os.tmpdir(), "watch-bundle-")), "Test.watch");
  mkdirSync(dir);
  copyFileSync(slides, path.join(dir, "video.mp4"));
  writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ format: "watch-bundle", version: 1, video: "video.mp4", createdAt: "2026-10-19T00:00:00Z", ...manifest }));
  if (timeline !== undefined) writeFileSync(path.join(dir, "timeline.json"), JSON.stringify(timeline));
  return dir;
}

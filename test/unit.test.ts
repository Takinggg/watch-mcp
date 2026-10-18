import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { WatchError } from "../src/errors.ts";
import { buildInfo, resolveLocalPath } from "../src/probe.ts";
import { selectKeyframes } from "../src/select.ts";
import { chooseGrid, composeSheet, LABEL_HEIGHT, layoutSheet } from "../src/storyboard.ts";
import { formatTime, parseTime } from "../src/time.ts";
import { keepSpoken } from "../src/transcribers/whisper-local.ts";
import { selectBackend } from "../src/transcribers/index.ts";
import { tokensToWords, wordsToSegments } from "../src/words.ts";
import { defaultBudget } from "../src/watch.ts";
import { zoomFps } from "../src/drilldown.ts";

describe("time", () => {
  it("parses seconds and clock strings", () => {
    assert.equal(parseTime(83.5, "t"), 83.5);
    assert.equal(parseTime("83.5", "t"), 83.5);
    assert.equal(parseTime("12s", "t"), 12);
    assert.equal(parseTime("01:23.5", "t"), 83.5);
    assert.equal(parseTime("1:02:03.25", "t"), 3723.25);
  });
  it("rejects garbage and negative values", () => {
    assert.throws(() => parseTime("soon", "t"), WatchError);
    assert.throws(() => parseTime(-1, "t"), WatchError);
    assert.throws(() => parseTime(Number.NaN, "t"), WatchError);
    assert.throws(() => parseTime("1:75:00", "t"), WatchError);
  });
  it("formats with rounding carried into seconds and hours", () => {
    assert.equal(formatTime(0), "00:00.0");
    assert.equal(formatTime(59.96), "01:00.0");
    assert.equal(formatTime(83.456, 2), "01:23.46");
    assert.equal(formatTime(3723.25, 1), "1:02:03.3");
    assert.equal(formatTime(5, 1, true), "0:00:05.0");
  });
});

describe("storyboard layout", () => {
  it("packs 16 landscape frames 4x4 within the size limit", () => {
    const grid = chooseGrid(16 / 9, { perSheet: 16, maxEdge: 1568, gutter: 4 });
    assert.deepEqual([grid.cols, grid.rows], [4, 4]);
    const sheet = layoutSheet(grid, 16);
    assert.ok(sheet.width <= 1568 && sheet.height <= 1568, `${sheet.width}x${sheet.height}`);
    assert.ok(Math.abs(grid.tileW / grid.tileH - 16 / 9) < 0.02);
  });
  it("keeps portrait and ultrawide sheets within the limit and grids exact", () => {
    for (const aspect of [9 / 16, 21 / 9, 1, 4 / 3]) {
      const grid = chooseGrid(aspect, { perSheet: 16, maxEdge: 1568, gutter: 4 });
      const sheet = layoutSheet(grid, 16);
      assert.equal(grid.cols * grid.rows, 16);
      assert.ok(sheet.width <= 1568 && sheet.height <= 1568, `aspect ${aspect}: ${sheet.width}x${sheet.height}`);
    }
  });
  it("shrinks the last sheet without changing tile size", () => {
    const grid = chooseGrid(16 / 9, { perSheet: 16, maxEdge: 1568, gutter: 4 });
    const five = layoutSheet(grid, 5);
    assert.equal(five.cols * five.rows - 5, 1);
    assert.equal(five.tileW, grid.tileW);
    assert.ok(five.height < layoutSheet(grid, 16).height);
  });
  it("draws the caption above the tile and copies tile pixels untouched", () => {
    const grid = { cols: 2, rows: 1, tileW: 40, tileH: 20, gutter: 2, labelH: LABEL_HEIGHT };
    const layout = layoutSheet(grid, 2);
    const red = Buffer.alloc(40 * 20 * 3);
    for (let i = 0; i < red.length; i += 3) red[i] = 200;
    const canvas = composeSheet(layout, [{ rgb: red, label: "#1 00:00.0" }, { rgb: red, label: "#2" }]);
    const px = (x: number, y: number) => [...canvas.data.subarray((y * canvas.width + x) * 3, (y * canvas.width + x) * 3 + 3)];
    // Bottom-right pixel of the first tile is the tile's own color.
    assert.deepEqual(px(2 + 39, 2 + LABEL_HEIGHT + 19), [200, 0, 0]);
    // Some caption pixels are white (text was drawn in the strip).
    let white = 0;
    for (let y = 2; y < 2 + LABEL_HEIGHT; y += 1) for (let x = 2; x < 42; x += 1) if (px(x, y)[0] === 255) white += 1;
    assert.ok(white > 10, `white caption pixels: ${white}`);
  });
});

/** Builds 32x16 signatures from a list of "scenes": [frameCount, grayLevel, optional changed pixels]. */
function sigs(scenes: Array<[number, number, number?]>): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (const [count, gray, spots = 0] of scenes) {
    for (let i = 0; i < count; i += 1) {
      const sig = new Uint8Array(32 * 16).fill(gray);
      for (let p = 0; p < spots; p += 1) sig[p] = 255;
      out.push(sig);
    }
  }
  return out;
}

describe("keyframe selection", () => {
  it("collapses a static video to the first frame", () => {
    const picked = selectKeyframes(sigs([[100, 50]]), { budget: 16 });
    assert.deepEqual(picked.map((p) => p.index), [0]);
    assert.equal(picked[0]?.sameUntil, 99);
  });
  it("keeps one frame per scene and flags hard cuts", () => {
    const picked = selectKeyframes(sigs([[40, 20], [40, 200], [40, 90]]), { budget: 16 });
    assert.deepEqual(picked.map((p) => p.index), [0, 40, 80]);
    assert.deepEqual(picked.map((p) => p.cut), [false, true, true]);
  });
  it("shows a one-sample flicker that reverts", () => {
    const picked = selectKeyframes(sigs([[30, 20], [1, 20, 60], [30, 20]]), { budget: 8 });
    assert.ok(picked.some((p) => p.index === 30), JSON.stringify(picked.map((p) => p.index)));
  });
  it("keeps a small localized change even next to a busy part", () => {
    // 20 static, a 6-pixel change (e.g. a word in a menu), then 60 samples of constant motion.
    const scenes: Array<[number, number, number?]> = [[20, 20], [20, 20, 6]];
    for (let i = 0; i < 60; i += 1) scenes.push([1, (i * 37) % 250]);
    const picked = selectKeyframes(sigs(scenes), { budget: 10, mergeGapSamples: 1 });
    assert.ok(picked.length <= 10);
    assert.ok(picked.some((p) => p.index === 20), JSON.stringify(picked.map((p) => p.index)));
  });
  it("never exceeds the budget and spends more frames on busy parts", () => {
    const scenes: Array<[number, number, number?]> = [[100, 30]];
    for (let i = 0; i < 100; i += 1) scenes.push([1, (i * 53) % 256]);
    const picked = selectKeyframes(sigs(scenes), { budget: 12 });
    assert.ok(picked.length <= 12, `${picked.length}`);
    const inBusy = picked.filter((p) => p.index >= 100).length;
    assert.ok(inBusy >= picked.length - 2, `busy ${inBusy} of ${picked.length}`);
  });
  it("keeps forced samples (recorded clicks) even in a static stretch", () => {
    const picked = selectKeyframes(sigs([[100, 50]]), { budget: 8, forced: [42, 77] });
    assert.deepEqual(picked.map((p) => p.index), [0, 42, 77]);
  });
  it("caps forced samples at half the budget, spread over the video", () => {
    const forced = Array.from({ length: 40 }, (_, i) => i * 2 + 1);
    const picked = selectKeyframes(sigs([[100, 50]]), { budget: 10, forced });
    assert.ok(picked.length <= 10);
    assert.equal(picked.length, 1 + Math.floor((10 - 1 - 1) / 2));
    assert.ok((picked.at(-1)?.index ?? 0) > 60, JSON.stringify(picked.map((p) => p.index)));
  });
  it("includes the final picture when it differs", () => {
    const picked = selectKeyframes(sigs([[50, 10], [1, 240]]), { budget: 4 });
    assert.equal(picked.at(-1)?.index, 50);
  });
});

describe("budgets", () => {
  it("rounds the default budget up to whole storyboards", () => {
    assert.equal(defaultBudget(10), 16);
    assert.equal(defaultBudget(60), 32);
    assert.equal(defaultBudget(150), 64);
    assert.equal(defaultBudget(3600), 64);
  });
  it("follows the recording preset of a bundle", () => {
    assert.equal(defaultBudget(60, "light"), 16);
    assert.equal(defaultBudget(600, "light"), 32);
    assert.equal(defaultBudget(60, "detailed"), 48);
    assert.equal(defaultBudget(3600, "detailed"), 128);
  });
  it("caps zoom density by frame count and source rate", () => {
    assert.equal(zoomFps(2, 30), 24);
    assert.equal(zoomFps(1, 30), 30);
    assert.equal(zoomFps(10, 30, 60), 4.8);
    assert.equal(zoomFps(1, 30, 5), 5);
  });
});

describe("probe parsing", () => {
  const stat = { sizeBytes: 1, mtimeMs: 0 };
  it("swaps width and height for rotated phone videos", () => {
    const info = buildInfo("/x.mov", {
      format: { format_name: "mov,mp4,m4a,3gp,3g2,mj2", duration: "12.5" },
      streams: [{ codec_type: "video", codec_name: "hevc", width: 1920, height: 1080, avg_frame_rate: "30000/1001", side_data_list: [{ rotation: -90 }] }],
    }, stat);
    assert.deepEqual([info.width, info.height], [1080, 1920]);
    assert.ok(Math.abs(info.fps - 29.97) < 0.01);
    assert.equal(info.hasAudio, false);
  });
  it("rejects playlists, images and audio-only files", () => {
    assert.throws(() => buildInfo("/x.m3u8", { format: { format_name: "hls" }, streams: [] }, stat), /Unsupported container/);
    assert.throws(() => buildInfo("/x.m4a", { format: { format_name: "mov,mp4,m4a,3gp,3g2,mj2" }, streams: [{ codec_type: "audio" }] }, stat), /no video stream/);
  });
  it("refuses URLs and missing files with a clear message", () => {
    assert.throws(() => resolveLocalPath("https://example.com/a.mp4"), /only reads local files/);
    assert.throws(() => resolveLocalPath("/definitely/not/here.mp4"), /No file at/);
  });
});

describe("transcript filtering", () => {
  it("drops text Whisper invents over silence", () => {
    const kept = keepSpoken(
      [
        { start: 0, end: 2, text: "Hello there." },
        { start: 10, end: 12, text: "Thanks for watching!" },
        { start: 20, end: 21, text: "  " },
      ],
      [[0.1, 1.9], [19.5, 21]],
    );
    assert.deepEqual(kept.map((s) => s.text), ["Hello there."]);
  });
});

describe("words", () => {
  it("joins Whisper token pieces into words", () => {
    const tokens = [" Je", " vous", " l", "'", "ex", "port", "."].map((text, i) => ({ start: i * 0.25, end: i * 0.25 + 0.25, text }));
    const words = tokensToWords([{ start: 0, end: 0, text: "" }, ...tokens]);
    assert.deepEqual(words.map((w) => w.text), ["Je", "vous", "l'export."]);
    assert.deepEqual([words[2]?.start, words[2]?.end], [0.5, 1.75]);
  });
  it("groups words into segments at sentence ends and pauses", () => {
    const w = (text: string, start: number) => ({ start, end: start + 0.3, text });
    const segments = wordsToSegments([w("Bonjour.", 0), w("Regarde", 0.5), w("ça", 0.9), w("ici", 3)]);
    assert.deepEqual(segments.map((s) => s.text), ["Bonjour.", "Regarde ça", "ici"]);
    assert.deepEqual([segments[1]?.start, segments[1]?.end], [0.5, 1.2]);
  });
});

describe("transcription backends", () => {
  it("defaults to local Whisper and rejects unknown names with the list", () => {
    const previous = process.env.WATCH_MCP_TRANSCRIBER;
    try {
      delete process.env.WATCH_MCP_TRANSCRIBER;
      assert.match(selectBackend().id, /^whisper-local:/);
      process.env.WATCH_MCP_TRANSCRIBER = "telepathy";
      assert.throws(() => selectBackend(), /Unknown WATCH_MCP_TRANSCRIBER "telepathy". Available: whisper-local/);
    } finally {
      if (previous === undefined) delete process.env.WATCH_MCP_TRANSCRIBER;
      else process.env.WATCH_MCP_TRANSCRIBER = previous;
    }
  });
});

describe("speech packing", async () => {
  const { packSpeech, toOriginalTime, SAMPLE_RATE } = await import("../src/speech-pack.ts");
  it("keeps only speech and maps packed times back to the original", () => {
    const seconds = 20;
    const pcm = Buffer.alloc(seconds * SAMPLE_RATE * 2);
    const { audio, pieces } = packSpeech(pcm, [[2, 3], [13, 15]], seconds);
    // 1.4 s + 0.3 s gap + 2.4 s of audio instead of 20 s.
    assert.ok(Math.abs(audio.length / 2 / SAMPLE_RATE - 4.1) < 0.01, `${audio.length / 2 / SAMPLE_RATE}`);
    assert.ok(Math.abs(toOriginalTime(pieces, 0) - 1.8) < 0.01);
    assert.ok(Math.abs(toOriginalTime(pieces, 1.7) - 12.8) < 0.01);
    assert.ok(Math.abs(toOriginalTime(pieces, 2.7) - 13.8) < 0.01);
  });
  it("merges regions whose padding overlaps", () => {
    const pcm = Buffer.alloc(10 * SAMPLE_RATE * 2);
    const { pieces } = packSpeech(pcm, [[1, 2], [2.3, 3]], 10);
    assert.equal(pieces.length, 1);
  });
});

import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { frameTimes, hasSay, jpegSize, shortClip, slidesVideo } from "./fixtures.ts";
import { frameStill, zoomVideo } from "../src/drilldown.ts";
import { probeVideo } from "../src/probe.ts";
import { watchVideo } from "../src/watch.ts";
import { selectBackend } from "../src/transcribers/index.ts";

let slides = "";
before(() => {
  slides = slidesVideo();
});

describe("watch_video pipeline", () => {
  it("puts keyframes at the scene changes and collapses static parts", async () => {
    const out = await watchVideo({ path: slides, transcript: false });
    const times = frameTimes(out.outro);
    assert.equal(times[0], 0);
    for (const cut of [4, 8, 12]) {
      assert.ok(times.some((t) => Math.abs(t - cut) <= 0.25), `no keyframe near ${cut}s in ${times.join(", ")}`);
    }
    // Static stretches get exactly one frame each.
    assert.equal(times.filter((t) => t < 3.9).length, 1, `frames in 0-4 s: ${times.join(", ")}`);
    assert.equal(times.filter((t) => t > 4.25 && t < 7.9).length, 0, `frames inside the static red part: ${times.join(", ")}`);
    assert.ok(times.filter((t) => t > 12.25).length <= 1, `frames in the static tail: ${times.join(", ")}`);
    // The moving part gets the most frames.
    assert.ok(times.filter((t) => t >= 8 && t < 12).length >= 6, `moving part: ${times.join(", ")}`);
    assert.match(out.outro, /unchanged until 00:07\.9/);
    assert.match(out.outro, /cut \(new scene\)/);
  });

  it("returns JPEG storyboards within the image limits", async () => {
    const out = await watchVideo({ path: slides, transcript: false, budget: 40 });
    assert.ok(out.images.length >= 1 && out.images.length <= 3);
    for (const image of out.images) {
      const { width, height } = jpegSize(image.jpeg);
      assert.ok(width <= 1568 && height <= 1568, `${width}x${height}`);
      assert.match(image.caption, /^Storyboard \d+\/\d+: frames #\d+-#\d+/);
    }
    assert.match(out.intro, /VIDEO slides\.mp4: 00:20\.0, 640x360, 25 fps, h264/);
  });

  it("serves the second identical call from the cache", async () => {
    const first = await watchVideo({ path: slides, transcript: false, budget: 24 });
    const start = performance.now();
    const second = await watchVideo({ path: slides, transcript: false, budget: 24 });
    assert.ok(performance.now() - start < 300, "cached call should not decode the video again");
    assert.deepEqual(second.images.map((i) => i.jpeg.length), first.images.map((i) => i.jpeg.length));
  });

  it("watches a sub-range only", async () => {
    const out = await watchVideo({ path: slides, transcript: false, start: 8, end: 12 });
    const times = frameTimes(out.outro);
    assert.ok(times.every((t) => t >= 8 && t <= 12), times.join(", "));
    assert.match(out.intro, /Range watched: 00:08\.0 to 00:12\.0/);
  });

  it("rejects an empty range and a missing file", async () => {
    await assert.rejects(watchVideo({ path: slides, start: 15, end: 15 }), /Empty range/);
    await assert.rejects(watchVideo({ path: "/nope/missing.mov" }), /No file at/);
  });
});

describe("zoom and frame", () => {
  it("zoom returns consecutive frames at the requested rate", async () => {
    const out = await zoomVideo({ path: slides, start: 8, end: 9, fps: 10 });
    const labels = [...out.images.map((i) => i.caption).join(" ").matchAll(/#(\d+)/g)];
    assert.ok(labels.length >= 1);
    assert.match(out.intro, /10 consecutive frames at 10\.00 fps/);
  });

  it("zoom lowers fps to stay within the frame cap and says so", async () => {
    const out = await zoomVideo({ path: slides, start: 0, end: 20, fps: 25 });
    assert.match(out.intro, /requested fps was lowered/);
    assert.match(out.intro, /48 consecutive frames/);
    assert.equal(out.images.length, 3);
  });

  it("frame returns the full resolution, and a crop of it", async () => {
    const full = await frameStill({ path: slides, t: 10 });
    assert.deepEqual(jpegSize(full.images[0]!.jpeg), { width: 640, height: 360 });
    assert.match(full.intro, /full resolution/);
    const crop = await frameStill({ path: slides, t: 10, crop: { x: 0.5, y: 0.5, width: 0.5, height: 0.5 } });
    assert.deepEqual(jpegSize(crop.images[0]!.jpeg), { width: 320, height: 180 });
  });

  it("frame near the very end still decodes", async () => {
    const out = await frameStill({ path: slides, t: 20 });
    assert.equal(out.images.length, 1);
  });

  it("rejects a crop outside the frame", async () => {
    await assert.rejects(frameStill({ path: slides, t: 1, crop: { x: 0.8, y: 0, width: 0.5, height: 0.5 } }), /crop must be fractions/);
  });
});

describe("formats", () => {
  for (const ext of ["mov", "mkv", "webm"] as const) {
    it(`reads ${ext}`, async () => {
      const clip = shortClip(ext);
      const info = await probeVideo(clip);
      assert.equal(info.width, 320);
      assert.ok(Math.abs(info.duration - 3) < 0.1, `duration ${info.duration}`);
      const out = await watchVideo({ path: clip });
      assert.ok(out.images.length === 1);
      assert.match(out.outro, /no audio track/);
    });
  }
});

const modelsReady = selectBackend().availability().ready;

describe("transcription", { skip: !hasSay ? "needs macOS `say` to create speech" : !modelsReady ? "speech models not downloaded (run: node src/cli.ts setup)" : false }, () => {
  it("transcribes speech at the right time and aligns it in the timeline", async () => {
    const out = await watchVideo({ path: slides, budget: 16 });
    assert.match(out.outro, /Speech: \d+ segment\(s\), language en/);
    const speech = /SAID (\d\d):(\d\d\.\d)-\d\d:\d\d\.\d: "([^"]+)"/.exec(out.outro);
    assert.ok(speech, out.outro);
    const start = Number(speech[1]) * 60 + Number(speech[2]);
    assert.ok(start >= 12.5 && start <= 14, `speech starts at ${start}`);
    assert.match(speech[3] ?? "", /export/i);
  });
});

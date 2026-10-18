import assert from "node:assert/strict";
import { readFileSync, symlinkSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { before, describe, it } from "node:test";
import { readBundle, updateTimeline } from "../src/bundle.ts";
import { zoomVideo } from "../src/drilldown.ts";
import { finalizeBundle } from "../src/finalize.ts";
import { watchVideo } from "../src/watch.ts";
import { fortySeconds, frameTimes, makeBundle, slidesVideo } from "./fixtures.ts";

let slides = "";
before(() => {
  slides = slidesVideo();
});

const EVENTS = [
  { t: 1.0, type: "app", name: "Safari" },
  { t: 6.0, type: "click", button: "left", x: 0.25, y: 0.5, app: "Safari" },
  { t: 9.5, type: "typing", duration: 1.5, keys: 12, app: "Safari" },
  { t: 10.0, type: "hologram", intensity: 3 },
];

describe("recording bundles", () => {
  it("reads the manifest, the video and the known events in time order", () => {
    const bundle = readBundle(makeBundle({ version: 1, events: [...EVENTS].reverse() }));
    assert.equal(path.basename(bundle.videoPath), "video.mp4");
    assert.deepEqual(bundle.timeline.events.map((e) => e.type), ["app", "click", "typing"]);
  });

  it("refuses a video path that leaves the bundle", () => {
    assert.throws(() => readBundle(makeBundle(undefined, { video: "../video.mp4" })), /relative "video" path/);
    assert.throws(() => readBundle(makeBundle(undefined, { video: "/etc/hosts" })), /relative "video" path/);
    const dir = makeBundle(undefined, { video: "link.mp4" });
    symlinkSync(slides, path.join(dir, "link.mp4"));
    assert.throws(() => readBundle(dir), /must be inside the bundle/);
  });

  it("rejects a folder that is not a bundle, with a clear message", async () => {
    await assert.rejects(watchVideo({ path: os.tmpdir() }), /is a folder, not a video file or a \.watch recording bundle/);
  });

  it("watch_video keeps a frame at each click, circles it, and lists what was done", async () => {
    const out = await watchVideo({ path: makeBundle({ version: 1, events: EVENTS }), transcript: false });
    const times = frameTimes(out.outro);
    // 4-8 s is static red: without the click there is no frame inside it.
    assert.ok(times.some((t) => t > 5.7 && t <= 6.0), times.join(", "));
    assert.match(out.intro, /^RECORDING BUNDLE Test\.watch: 3 recorded input event/);
    assert.match(out.outro, /00:06\.0  DONE left click at x 25%, y 50% in Safari/);
    assert.match(out.outro, /SEEN #\d+ \(storyboard 1\)  [^\n]*click circled in yellow/);
    assert.match(out.outro, /00:09\.5  DONE typed for 1\.5 s \(12 keys, contents not recorded\) in Safari/);
    assert.match(out.outro, /00:01\.0  DONE switched to Safari/);
  });

  it("zoom lists the events in its range", async () => {
    const out = await zoomVideo({ path: makeBundle({ version: 1, events: EVENTS }), start: 5.5, end: 6.5, fps: 10 });
    assert.match(out.outro, /DONE 00:06\.00  left click at x 25%, y 50% in Safari/);
    assert.doesNotMatch(out.outro, /typed/);
  });

  it("uses the bundle's quality preset for the default number of keyframes", async () => {
    // 40 s: Light asks one keyframe per 6 s (one storyboard of 16), Detailed one per 1.5 s (two).
    const video = fortySeconds();
    const light = await watchVideo({ path: makeBundle({ version: 1, events: [] }, { quality: "light" }, video), transcript: false });
    const detailed = await watchVideo({ path: makeBundle({ version: 1, events: [] }, { quality: "detailed" }, video), transcript: false });
    const plain = await watchVideo({ path: makeBundle({ version: 1, events: [] }, {}, video), transcript: false });
    assert.match(light.intro, /\(budget 16\)/);
    assert.match(detailed.intro, /\(budget 32\)/);
    assert.match(plain.intro, /\(budget 16\)/);
  });

  it("uses the transcript a bundle already carries", async () => {
    const speech = { source: "test-engine", language: "en", segments: [{ start: 2, end: 3, text: "click the red one" }], words: [] };
    const out = await watchVideo({ path: makeBundle({ version: 1, events: [], speech }) });
    assert.match(out.outro, /SAID 00:02\.0-00:03\.0: "click the red one"/);
    assert.match(out.outro, /from the recording bundle, test-engine/);
  });

  it("finalize writes speech and keyframes and keeps everything else", async () => {
    const dir = makeBundle({ version: 1, events: EVENTS, producerNote: "kept" });
    const summary = await finalizeBundle(dir);
    const timeline = JSON.parse(readFileSync(path.join(dir, "timeline.json"), "utf8"));
    assert.equal(timeline.producerNote, "kept");
    assert.equal(timeline.events.length, 4, "unknown event types are preserved on disk");
    assert.equal(timeline.keyframes.length, summary.keyframes);
    assert.ok(timeline.keyframes.some((k: { t: number }) => k.t > 5.7 && k.t <= 6));
    assert.ok(["ok", "no-speech", "pending", "unavailable", "skipped"].includes(summary.status));
  });

  it("updateTimeline creates timeline.json when the recorder wrote none", () => {
    const dir = makeBundle(undefined);
    updateTimeline(dir, { keyframes: [{ t: 0, change: 0, cut: false }] });
    const timeline = JSON.parse(readFileSync(path.join(dir, "timeline.json"), "utf8"));
    assert.deepEqual(timeline, { version: 1, events: [], keyframes: [{ t: 0, change: 0, cut: false }] });
  });
});

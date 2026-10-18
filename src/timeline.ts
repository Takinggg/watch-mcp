import type { BundleEvent } from "./bundle.ts";
import type { VideoInfo } from "./probe.ts";
import { formatTime } from "./time.ts";
import { describeTranscript, type TranscriptResult } from "./transcribe.ts";

export interface TimelineFrame {
  /** 1-based frame number, as burned into the tile label. */
  n: number;
  t: number;
  /** Share of the picture that changed since the previous keyframe (0..1). */
  change: number;
  cut: boolean;
  /** Time until which the picture stays the same as this frame. */
  sameUntil: number;
  sheet: number;
  /** Recorded clicks drawn on this tile, as fractions of the frame. */
  marks?: Array<{ x: number; y: number }>;
}

interface TimelineInput {
  info: VideoInfo;
  frames: readonly TimelineFrame[];
  transcript: TranscriptResult;
  range: { start: number; end: number };
  /** Input events from a recording bundle (empty for a plain video). */
  events?: readonly BundleEvent[];
}

const STATIC_NOTE_SECONDS = 2;

/**
 * One chronological list of what was SEEN (keyframes), DONE (clicks, typing,
 * app switches from a recording bundle) and SAID (transcript), so Claude can
 * line up what is shown with what is said and done.
 */
export function buildTimeline(input: TimelineInput): string {
  const withHours = input.info.duration >= 3600;
  const fmt = (t: number): string => formatTime(t, 1, withHours);
  const rows: Array<{ t: number; order: number; text: string }> = [];
  for (const f of input.frames) rows.push({ t: f.t, order: 0, text: `${fmt(f.t)}  SEEN #${f.n} (storyboard ${f.sheet})  ${frameNote(f, fmt)}` });
  for (const e of input.events ?? []) {
    if (e.t < input.range.start || e.t > input.range.end) continue;
    rows.push({ t: e.t, order: 1, text: `${fmt(e.t)}  DONE ${describeEvent(e)}` });
  }
  if (input.transcript.kind === "ok") {
    for (const s of input.transcript.segments) {
      if (s.end < input.range.start || s.start > input.range.end) continue;
      rows.push({ t: s.start, order: 2, text: `${fmt(s.start)}  SAID ${fmt(s.start)}-${fmt(s.end)}: "${s.text}"` });
    }
  }
  rows.sort((a, b) => a.t - b.t || a.order - b.order);
  const legend = (input.events?.length ?? 0) > 0 ? "SEEN = keyframe, DONE = recorded input, SAID = speech" : "SEEN = keyframe, SAID = speech";
  return [describeTranscript(input.transcript), "", `TIMELINE (${legend}; in time order):`, ...rows.map((r) => r.text)].join("\n");
}

function frameNote(f: TimelineFrame, fmt: (t: number) => string): string {
  const parts: string[] = [];
  if (f.n === 1) parts.push("start");
  else if (f.cut) parts.push("cut (new scene)");
  else parts.push(describeChange(f.change));
  if ((f.marks?.length ?? 0) > 0) parts.push("click circled in yellow");
  if (f.sameUntil - f.t >= STATIC_NOTE_SECONDS) parts.push(`unchanged until ${fmt(f.sameUntil)}`);
  return parts.join("; ");
}

function describeChange(change: number): string {
  const pct = change * 100;
  return pct < 1 ? "small change (<1% of the picture)" : `${Math.round(pct)}% of the picture changed`;
}

export function describeEvent(e: BundleEvent): string {
  const where = e.type !== "app" && e.app ? ` in ${e.app}` : "";
  switch (e.type) {
    case "click":
      return `${e.button} click at x ${Math.round(e.x * 100)}%, y ${Math.round(e.y * 100)}%${where}`;
    case "typing":
      return `typed for ${e.duration.toFixed(1)} s (${e.keys} keys, contents not recorded)${where}`;
    case "shortcut":
      return `keyboard shortcut with ${e.modifiers.join("+") || "no modifier"} (key not recorded)${where}`;
    case "app":
      return `switched to ${e.name}`;
  }
}

import { createRequire } from "node:module";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { frameStill, MAX_FRAME_EDGE, MAX_ZOOM_FRAMES, zoomVideo } from "./drilldown.ts";
import { describeError } from "./errors.ts";
import { latestPromptText, latestRecordingTool } from "./latest-tool.ts";
import { readLatestRecording } from "./recordings.ts";
import { parseTime } from "./time.ts";
import { transcribeTool } from "./transcribe-tool.ts";
import { MAX_BUDGET, watchVideo, type ProgressFn, type ToolOutput } from "./watch.ts";

const require = createRequire(import.meta.url);
const pkg = require("../package.json") as { version: string };

const INSTRUCTIONS = `watch-mcp lets you watch local video files (mp4, mov, mkv, webm).
Start with watch_video: it returns storyboard images (keyframes picked where the picture changes, each tile labelled "#frame mm:ss.s") and a timeline that lines up the keyframes with a timestamped transcript of the audio.
For a .watch recording bundle, the timeline also lists what the user DID (clicks, typing, app switches), and clicks are circled in yellow on the frame taken at that moment.
Then drill down only where needed: zoom for dense consecutive frames of a short segment (motion, flicker, animations), frame for one full-resolution still (small on-screen text; use crop to enlarge a region).
When the user says they just recorded their screen (or pastes a WatchRecorder prompt), call latest_recording.
Refer to moments by timestamp and frame number. Everything runs locally; nothing is uploaded.`;

const timeSchema = z.union([z.number(), z.string()]);

const cropSchema = z
  .object({
    x: z.number().min(0).max(1).describe("Left edge, as a fraction of the frame width (0-1)."),
    y: z.number().min(0).max(1).describe("Top edge, as a fraction of the frame height (0-1)."),
    width: z.number().gt(0).max(1).describe("Region width, as a fraction of the frame width."),
    height: z.number().gt(0).max(1).describe("Region height, as a fraction of the frame height."),
  })
  .describe("Optional region of the picture to enlarge, in fractions of the frame (e.g. the top-right quarter is {x:0.5,y:0,width:0.5,height:0.5}).");

const pathSchema = z.string().min(1).describe("Absolute path to a local video file (mp4, mov, mkv, webm) or a .watch recording bundle folder. ~ is expanded.");

export function createServer(): McpServer {
  const server = new McpServer({ name: "watch-mcp", version: pkg.version }, { instructions: INSTRUCTIONS });

  server.registerTool(
    "watch_video",
    {
      title: "Watch a video",
      description:
        "Watch a local video. Returns storyboard images of adaptively chosen keyframes (more frames where things change, few in static parts; each tile shows its frame number and timestamp) plus a timeline aligning those frames with a timestamped speech transcript (local Whisper). Use this first for any video or screen recording.",
      inputSchema: {
        path: pathSchema,
        budget: z.number().int().min(4).max(MAX_BUDGET).optional().describe(`Maximum number of keyframes (default: about one per 3 s, rounded up to whole storyboards of 16, between 16 and 64). Raise it (up to ${MAX_BUDGET}) for a denser overview; 16 keyframes fit on one image.`),
        start: timeSchema.optional().describe("Only watch from this time (seconds or mm:ss)."),
        end: timeSchema.optional().describe("Only watch until this time (seconds or mm:ss)."),
        transcript: z.boolean().optional().describe("Transcribe the audio (default true)."),
        language: z.string().optional().describe('Spoken language as a 2-letter code ("en", "fr", "ko"...). Default: auto-detect.'),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args, extra) =>
      respond(() =>
        watchVideo({
          path: args.path,
          budget: args.budget,
          start: args.start === undefined ? undefined : parseTime(args.start, "start"),
          end: args.end === undefined ? undefined : parseTime(args.end, "end"),
          transcript: args.transcript,
          language: args.language,
          signal: extra.signal,
          onProgress: progressReporter(extra),
        }),
      ),
  );

  server.registerTool(
    "zoom",
    {
      title: "Zoom into a segment",
      description: `Dense consecutive frames of a short segment (up to ${MAX_ZOOM_FRAMES} frames), to see motion: a flickering bug, an animation, a quick transition. Use after watch_video, with start/end taken from its timeline.`,
      inputSchema: {
        path: pathSchema,
        start: timeSchema.describe("Segment start (seconds or mm:ss.s)."),
        end: timeSchema.describe("Segment end (seconds or mm:ss.s). Keep it short (a few seconds) for a dense view."),
        fps: z.number().gt(0).max(120).optional().describe(`Frames per second to sample (default: as dense as fits in ${MAX_ZOOM_FRAMES} frames, up to the source rate).`),
        crop: cropSchema.optional(),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args, extra) =>
      respond(() =>
        zoomVideo({
          path: args.path,
          start: parseTime(args.start, "start"),
          end: parseTime(args.end, "end"),
          fps: args.fps,
          crop: args.crop,
          signal: extra.signal,
          onProgress: progressReporter(extra),
        }),
      ),
  );

  server.registerTool(
    "frame",
    {
      title: "Get one full-resolution frame",
      description: `One still frame at full resolution (long edge up to ${MAX_FRAME_EDGE} px), to read small on-screen text or inspect details. Pass crop to enlarge a region.`,
      inputSchema: {
        path: pathSchema,
        t: timeSchema.describe("Time of the frame (seconds or mm:ss.s)."),
        crop: cropSchema.optional(),
        max_edge: z.number().int().min(64).max(MAX_FRAME_EDGE).optional().describe(`Longest edge of the returned image in pixels (default ${MAX_FRAME_EDGE}).`),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args, extra) =>
      respond(() => frameStill({ path: args.path, t: parseTime(args.t, "t"), crop: args.crop, maxEdge: args.max_edge, signal: extra.signal })),
  );

  server.registerTool(
    "transcribe",
    {
      title: "Transcribe a video's speech",
      description:
        "Timestamped transcript of the speech in a local video, made locally with Whisper (text only, no images). Use it when watch_video said the transcript was pending, or when only the words matter.",
      inputSchema: {
        path: pathSchema,
        language: z.string().optional().describe('Spoken language as a 2-letter code ("en", "fr", "ko"...). Default: auto-detect.'),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args, extra) =>
      respond(() => transcribeTool({ path: args.path, language: args.language, signal: extra.signal, onProgress: progressReporter(extra) })),
  );

  server.registerTool(
    "latest_recording",
    {
      title: "Watch my latest screen recording",
      description:
        "The most recent screen + voice recording made with the WatchRecorder menu-bar app (macOS companion of watch-mcp). Returns the same storyboards and timeline as watch_video: what the user showed, and what they asked out loud. Use it when the user says they just recorded something or pastes a WatchRecorder prompt.",
      inputSchema: {
        budget: z.number().int().min(4).max(MAX_BUDGET).optional().describe("Maximum number of keyframes (default as in watch_video)."),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args, extra) =>
      respond(() => latestRecordingTool({ budget: args.budget, signal: extra.signal, onProgress: progressReporter(extra) })),
  );

  server.registerPrompt(
    "latest",
    {
      title: "Watch my latest recording",
      description: "Puts the latest WatchRecorder recording (path and what you said) into this conversation, so Claude watches it.",
    },
    () => {
      let text: string;
      try {
        text = latestPromptText();
      } catch (err) {
        text = describeError(err);
      }
      return { messages: [{ role: "user", content: { type: "text", text } }] };
    },
  );

  server.registerResource(
    "latest-recording",
    "watch://recordings/latest",
    {
      title: "Latest WatchRecorder recording",
      description: "Path, start time, duration and spoken transcript of the most recent recording (JSON, or null when there is none).",
      mimeType: "application/json",
    },
    async (uri) => {
      let text: string;
      try {
        text = JSON.stringify(readLatestRecording());
      } catch (err) {
        text = JSON.stringify({ error: describeError(err) });
      }
      return { contents: [{ uri: uri.href, mimeType: "application/json", text }] };
    },
  );

  return server;
}

async function respond(task: () => Promise<ToolOutput>): Promise<CallToolResult> {
  try {
    return toContent(await task());
  } catch (err) {
    return { isError: true, content: [{ type: "text", text: describeError(err) }] };
  }
}

/** Text first, then each image preceded by its caption, then the timeline text. */
export function toContent(out: ToolOutput): CallToolResult {
  const content: CallToolResult["content"] = [];
  if (out.intro) content.push({ type: "text", text: out.intro });
  for (const image of out.images) {
    if (image.caption) content.push({ type: "text", text: image.caption });
    content.push({ type: "image", data: image.jpeg.toString("base64"), mimeType: "image/jpeg" });
  }
  if (out.outro) content.push({ type: "text", text: out.outro });
  return { content };
}

interface ProgressExtra {
  _meta?: { progressToken?: string | number } | undefined;
  sendNotification: (notification: { method: "notifications/progress"; params: { progressToken: string | number; progress: number; total: number; message: string } }) => Promise<void>;
}

/** Sends MCP progress notifications (at most 4 per second) when the client asked for them. */
function progressReporter(extra: ProgressExtra): ProgressFn {
  const token = extra._meta?.progressToken;
  let lastSent = 0;
  let lastValue = 0;
  return (message, fraction) => {
    if (token === undefined) return;
    const now = Date.now();
    const value = Math.max(lastValue, Math.round(Math.min(1, Math.max(0, fraction)) * 1000));
    if (now - lastSent < 250 && value < 1000) return;
    lastSent = now;
    lastValue = value;
    void extra
      .sendNotification({ method: "notifications/progress", params: { progressToken: token, progress: value, total: 1000, message } })
      .catch(() => undefined);
  };
}

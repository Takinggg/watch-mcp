import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { jpegSize, makeBundle, slidesVideo } from "./fixtures.ts";

const cli = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src", "cli.ts");

interface Block {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
}

describe("MCP server over stdio", () => {
  let client: Client;
  let slides = "";

  const stateDir = mkdtempSync(path.join(os.tmpdir(), "watch-mcp-state-"));

  before(async () => {
    slides = slidesVideo();
    process.env.WATCH_MCP_STATE_DIR = stateDir;
    const env = Object.fromEntries(Object.entries(process.env).filter((e): e is [string, string] => e[1] !== undefined));
    const transport = new StdioClientTransport({ command: process.execPath, args: [cli], env, stderr: "ignore" });
    client = new Client({ name: "watch-mcp-test", version: "0.0.0" });
    await client.connect(transport);
  });

  after(async () => {
    await client.close();
  });

  it("lists the tools with input schemas", async () => {
    const { tools } = await client.listTools();
    assert.deepEqual(tools.map((t) => t.name).sort(), ["frame", "latest_recording", "transcribe", "watch_video", "zoom"]);
    const watch = tools.find((t) => t.name === "watch_video");
    assert.deepEqual(watch?.inputSchema.required, ["path"]);
    assert.equal(watch?.annotations?.readOnlyHint, true);
  });

  it("watch_video returns text, JPEG images and a timeline, with progress", async () => {
    const progress: number[] = [];
    const result = await client.callTool(
      { name: "watch_video", arguments: { path: slides, transcript: false, budget: 20 } },
      undefined,
      { onprogress: (p) => progress.push(p.progress) },
    );
    const content = result.content as Block[];
    assert.equal(result.isError, undefined);
    const images = content.filter((b) => b.type === "image");
    assert.equal(images.length, 2);
    for (const image of images) {
      assert.equal(image.mimeType, "image/jpeg");
      const { width, height } = jpegSize(Buffer.from(image.data ?? "", "base64"));
      assert.ok(width <= 1568 && height <= 1568);
    }
    assert.match(content[0]?.text ?? "", /^VIDEO slides\.mp4/);
    assert.match(content.at(-1)?.text ?? "", /TIMELINE/);
    assert.ok(progress.length >= 2, `progress notifications: ${progress.length}`);
  });

  it("accepts mm:ss timestamps and returns one frame", async () => {
    const result = await client.callTool({ name: "frame", arguments: { path: slides, t: "00:10.0", max_edge: 320 } });
    const images = (result.content as Block[]).filter((b) => b.type === "image");
    assert.equal(images.length, 1);
    assert.deepEqual(jpegSize(Buffer.from(images[0]?.data ?? "", "base64")), { width: 320, height: 180 });
  });

  it("reports user errors as tool errors, not protocol failures", async () => {
    const result = await client.callTool({ name: "watch_video", arguments: { path: "/no/such/video.mp4" } });
    assert.equal(result.isError, true);
    assert.match((result.content as Block[])[0]?.text ?? "", /No file at \/no\/such\/video\.mp4/);
    const bad = await client.callTool({ name: "zoom", arguments: { path: slides, start: "soon", end: 3 } });
    assert.equal(bad.isError, true);
    assert.match((bad.content as Block[])[0]?.text ?? "", /start must be seconds/);
  });

  it("latest_recording explains how to record when there is no recording", async () => {
    const result = await client.callTool({ name: "latest_recording", arguments: {} });
    assert.equal(result.isError, true);
    assert.match((result.content as Block[])[0]?.text ?? "", /No recording yet/);
    const resource = await client.readResource({ uri: "watch://recordings/latest" });
    assert.equal((resource.contents[0] as { text?: string }).text, "null");
  });

  it("latest_recording watches the file the companion recorded", async () => {
    const startedAt = new Date(Date.now() - 120_000).toISOString();
    writeFileSync(path.join(stateDir, "latest-recording.json"), JSON.stringify({ version: 1, path: slides, startedAt, duration: 20, transcript: null }));
    const result = await client.callTool({ name: "latest_recording", arguments: { budget: 16 } });
    const content = result.content as Block[];
    assert.equal(result.isError, undefined);
    assert.match(content[0]?.text ?? "", /^LATEST RECORDING of the user's screen, made 2 min ago, 00:20\.0 long/);
    assert.ok(content.some((b) => b.type === "image"));
    const resource = await client.readResource({ uri: "watch://recordings/latest" });
    assert.equal(JSON.parse((resource.contents[0] as { text: string }).text).path, slides);
  });

  it("latest_recording reads a .watch bundle with its recorded clicks", async () => {
    const bundle = makeBundle({ version: 1, events: [{ t: 6, type: "click", button: "left", x: 0.5, y: 0.5, app: "Safari" }] });
    writeFileSync(path.join(stateDir, "latest-recording.json"), JSON.stringify({ version: 1, path: bundle, startedAt: new Date().toISOString(), duration: 20, transcript: null }));
    const result = await client.callTool({ name: "latest_recording", arguments: {} });
    const texts = (result.content as Block[]).filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n");
    assert.match(texts, /RECORDING BUNDLE Test\.watch/);
    assert.match(texts, /00:06\.0  DONE left click at x 50%, y 50% in Safari/);
  });

  it("offers a latest prompt that puts the recording into the conversation", async () => {
    const { prompts } = await client.listPrompts();
    assert.deepEqual(prompts.map((p) => p.name), ["latest"]);
    writeFileSync(path.join(stateDir, "latest-recording.json"), JSON.stringify({ version: 1, path: slides, startedAt: new Date().toISOString(), duration: 20, transcript: "fix the red screen" }));
    const prompt = await client.getPrompt({ name: "latest" });
    const text = (prompt.messages[0]?.content as { text?: string }).text ?? "";
    assert.match(text, /What I said: "fix the red screen"/);
    assert.match(text, /latest_recording/);
  });
});

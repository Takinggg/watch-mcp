// Builds demo/demo-screen.watch from demo/demo-screen.mp4: a recording bundle whose input
// events are synthetic but match what the fake app shows (typing 2-5 s, a click on Export
// at 9.0 s, a click on the language menu at 25.5 s, a switch to Finder at 34 s).
// Usage: node scripts/make-demo-bundle.mjs && node dist/cli.js finalize demo/demo-screen.watch
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const dir = path.join(root, "demo", "demo-screen.watch");
mkdirSync(dir, { recursive: true });
copyFileSync(path.join(root, "demo", "demo-screen.mp4"), path.join(dir, "video.mp4"));
const manifest = {
  format: "watch-bundle",
  version: 1,
  video: "video.mp4",
  createdAt: "2026-10-19T00:00:00.000Z",
  duration: 40,
  recorder: { name: "make-demo-bundle (synthetic events)", version: "1" },
};
// Click positions are fractions of the 1440x900 frame: Export button at (1335, 24), menu at (640, 320).
const events = [
  { t: 0.5, type: "app", name: "invoice-app" },
  { t: 2.0, type: "typing", duration: 3.0, keys: 96, app: "invoice-app" },
  { t: 9.0, type: "click", button: "left", x: 0.927, y: 0.027, app: "invoice-app" },
  { t: 25.5, type: "click", button: "left", x: 0.444, y: 0.356, app: "invoice-app" },
  { t: 30.0, type: "shortcut", modifiers: ["cmd"], app: "invoice-app" },
  { t: 34.0, type: "app", name: "Finder" },
];
writeFileSync(path.join(dir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
writeFileSync(path.join(dir, "timeline.json"), `${JSON.stringify({ version: 1, events }, null, 1)}\n`);
console.log(dir);

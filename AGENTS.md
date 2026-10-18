# AGENTS.md

Instructions for AI agents (Claude Code, Codex, Cursor...) working with this repository.

## If the user asked you to install watch-mcp

Goal: the user's AI apps can watch videos (`watch_video`, `zoom`, `frame`, `transcribe`, `latest_recording`), and, on a Mac, record their screen and voice with WatchRecorder.

1. **Check Node.js 20 or later**: `node --version`. If it is missing, tell the user to install it (macOS: `brew install node`) and stop.
2. **Register the MCP server in every AI client on this machine.** Show the plan first, then apply it once the user agrees, because it edits their client settings:

   ```bash
   npx -y watch-mcp install --dry-run
   npx -y watch-mcp install
   ```

   It handles Claude Code (`claude mcp add -s user`), Codex (`~/.codex/config.toml`), Claude Desktop and Cursor (their JSON configs). While Claude Desktop is open it rewrites its settings file and would drop the change, so `install` reports it as `blocked` and leaves it alone: ask the user to quit Claude Desktop (⌘Q) and run `install --client claude-desktop` again (if you are running inside Claude Desktop, tell them to do it after this conversation). It is idempotent and backs up every file it edits (`*.watch-mcp.bak`). `--client codex` (comma-separated list) limits it to some clients. From a clone of this repository, use `npm install && npm run build && node dist/cli.js install` instead of `npx`.
3. **Download the speech models now** (574 MB on Apple Silicon, 148 MB elsewhere), so the first video is fast: `npx -y watch-mcp setup`.
4. **Check**: `npx -y watch-mcp doctor` lists ffmpeg, the speech model and the data folder.
5. **Tell the user to restart** the clients that were changed (Claude Desktop and Codex read their settings at launch; Claude Code picks it up in a new session).
6. **WatchRecorder (macOS 15+, optional)**, the menu-bar recorder:

   ```bash
   git clone https://github.com/Takinggg/watch-mcp && cd watch-mcp
   npm install && npm run build
   cd companion && ./build-app.sh && open build/WatchRecorder.app
   ```

   The app then walks the user through the macOS permissions (Screen Recording, Microphone, optional Accessibility). You cannot grant those for them: they are the user's decision, in System Settings.

Do not edit the user's client configuration by hand when `watch-mcp install` can do it, and never remove other MCP servers from those files.

## If you are working on the code

- `src/`: the MCP server (TypeScript, strict). `npm test` runs every test (ffmpeg pipeline, MCP over stdio, transcription on macOS). `npm run typecheck` checks `src` and `test`.
- `companion/`: WatchRecorder (Swift 6, SwiftPM). `swift test` in `companion/`; `./build-app.sh` builds and signs the app.
- Keep functions short, check every fallible call, no `any`. Never commit `companion/.signing/` (local signing keychain and its password).
- The `.watch` recording bundle format is specified in the README; keep `src/bundle.ts` and the recorder in step.

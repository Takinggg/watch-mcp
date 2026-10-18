#!/usr/bin/env bash
# Builds docs/demo.gif from demo/demo-screen.mp4 (see make-demo-video.sh):
#   1. the screen recording, 2. the storyboard watch_video returns, 3. an excerpt of Claude's answer.
# The answer lines are condensed from a real `claude -p` run with watch-mcp on this video.
# macOS only (system fonts). Usage: scripts/make-demo-gif.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF="$(cd "$ROOT" && node -p 'require("ffmpeg-static")')"
SANS=/System/Library/Fonts/Helvetica.ttc
TMP="$(mktemp -d)"
mkdir -p "$ROOT/docs"

node "$ROOT/dist/cli.js" watch "$ROOT/demo/demo-screen.mp4" --out "$TMP/out" >/dev/null 2>&1

printf '1. A 40 s screen recording with a voice-over: "the Export dialog flickers..."' > "$TMP/t1.txt"
printf '2. watch_video: 15 keyframes on one storyboard + a timestamped transcript (1.8 s, local)' > "$TMP/t2.txt"
printf '3. Claude, after watch_video and zoom (excerpt of a real answer)' > "$TMP/t3.txt"
cat > "$TMP/answer.txt" <<'TXT'
Dialog flicker, 00:09.0 to 00:09.7
  Right after the click on Export, the "Export invoice as PDF" box
  appears and disappears about 5 times, then is gone.
  The code calls dialog.close() right after renderPdf(id),
  with the comment "closes before the user can confirm".

Scroll stutter, 00:34 to 00:39
  The list stays still for about 8 frames (0.27 s),
  then jumps up by exactly one row, then stays still again.
TXT

banner() { # $1 text file
  printf "drawbox=x=0:y=0:w=iw:h=44:color=black@0.85:t=fill,drawtext=fontfile=%s:textfile=%s:x=16:y=13:fontsize=19:fontcolor=white" "$SANS" "$1"
}
W=800; H=500
"$FF" -hide_banner -loglevel error -y \
  -ss 6 -t 6 -i "$ROOT/demo/demo-screen.mp4" \
  -ss 24.5 -t 2.5 -i "$ROOT/demo/demo-screen.mp4" \
  -loop 1 -t 4 -i "$TMP/out/storyboard-1.jpg" \
  -f lavfi -t 6 -i "color=c=0x111111:s=${W}x${H}:r=10" \
  -filter_complex "\
[0:v]fps=10,scale=-2:$((H - 44)),pad=${W}:${H}:(ow-iw)/2:44:color=0x111111,setsar=1,$(banner "$TMP/t1.txt")[a];\
[1:v]fps=10,scale=-2:$((H - 44)),pad=${W}:${H}:(ow-iw)/2:44:color=0x111111,setsar=1,$(banner "$TMP/t1.txt")[b];\
[2:v]fps=10,scale=-2:$((H - 44)),pad=${W}:${H}:(ow-iw)/2:44:color=0x111111,setsar=1,$(banner "$TMP/t2.txt")[c];\
[3:v]setsar=1,drawtext=fontfile=$SANS:textfile=$TMP/answer.txt:x=40:y=90:fontsize=21:line_spacing=9:fontcolor=0xeeeeee,$(banner "$TMP/t3.txt")[d];\
[a][b][c][d]concat=n=4:v=1:a=0,split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4" \
  "$ROOT/docs/demo.gif"
ls -la "$ROOT/docs/demo.gif"

#!/usr/bin/env bash
# Builds docs/watchrecorder.gif: a tour of WatchRecorder's screens (setup guide, library, a recording),
# drawn by the app itself (`--render-ui`) on the synthetic demo bundle, so nobody's screen is recorded.
# Needs companion/build/WatchRecorder.app (companion/build-app.sh) and demo/ (scripts/make-demo-bundle.mjs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF="$(cd "$ROOT" && node -p 'require("ffmpeg-static")')"
TMP="$(mktemp -d)"
"$ROOT/companion/build/WatchRecorder.app/Contents/MacOS/WatchRecorder" --render-ui "$TMP" "$ROOT/demo" --language en >/dev/null

W=960; H=600; HOLD=1.8; FADE=0.4
SHOTS=(onboarding-1-light onboarding-2-light onboarding-3-light onboarding-4-light onboarding-5-light onboarding-6-light dashboard-library-light dashboard-detail-light)
inputs=(); filters=""
for i in "${!SHOTS[@]}"; do
  inputs+=(-loop 1 -t "$HOLD" -i "$TMP/${SHOTS[$i]}.png")
  # Library pages are drawn tall: keep the top, at the window's proportions.
  crop=$([[ ${SHOTS[$i]} == dashboard-library-* ]] && echo "crop=iw:iw*${H}/${W}:0:0," || echo "")
  filters+="[$i:v]${crop}scale=${W}:${H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=0xF7F5F2,setsar=1,fps=12,format=rgb24[v$i];"
done
chain="[v0]"; offset=0
for ((i = 1; i < ${#SHOTS[@]}; i++)); do
  offset=$(echo "$offset + $HOLD - $FADE" | bc)
  filters+="${chain}[v$i]xfade=transition=fade:duration=$FADE:offset=$offset[x$i];"
  chain="[x$i]"
done
filters+="${chain}split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"
"$FF" -hide_banner -loglevel error -y "${inputs[@]}" -filter_complex "$filters" "$ROOT/docs/watchrecorder.gif"
ls -la "$ROOT/docs/watchrecorder.gif"

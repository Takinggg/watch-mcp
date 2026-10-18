#!/usr/bin/env bash
# Builds demo/demo-screen.mp4: a synthetic 40 s "screen recording" of a fake app
# (code editor, an Export dialog that flickers, a settings page, a scrolling list)
# with a French voice-over. Used for the README demo; nothing personal is recorded.
# macOS only (uses `say` and system fonts). Usage: scripts/make-demo-video.sh [ffmpeg]
set -euo pipefail
FF="${1:-$(node -p 'require("ffmpeg-static")')}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/demo"
TMP="$(mktemp -d)"
mkdir -p "$OUT_DIR"
MONO=/System/Library/Fonts/Menlo.ttc
SANS=/System/Library/Fonts/Helvetica.ttc
VOICE="Eddy (Français (France))"

say -v "$VOICE" -o "$TMP/v1.aiff" "Je vous montre un bug dans l'export."
say -v "$VOICE" -o "$TMP/v2.aiff" "Quand je clique sur Export, la fenêtre clignote puis disparaît."
say -v "$VOICE" -o "$TMP/v3.aiff" "Ensuite, dans les réglages, je passe la langue en coréen."
say -v "$VOICE" -o "$TMP/v4.aiff" "Et le défilement de la liste saccade. Corrige ces deux problèmes, s'il te plaît."

code_line() { # $1 text, $2 y, $3 appear-at seconds
  printf "drawtext=fontfile=%s:text='%s':x=300:y=%s:fontsize=22:fontcolor=0xd4d4d4:enable='between(t,%s,20)'," "$MONO" "$1" "$2" "$3"
}
V="color=c=0x1e1e1e:s=1440x900:r=30:d=40,format=rgb24,"
V+="drawbox=x=0:y=0:w=1440:h=48:color=0x333333:t=fill,"
V+="drawtext=fontfile=$SANS:text='invoice-app  -  src/export.ts':x=20:y=14:fontsize=20:fontcolor=0xcccccc,"
V+="drawbox=x=1260:y=8:w=150:h=32:color=0x0e639c:t=fill,"
V+="drawtext=fontfile=$SANS:text='Export':x=1305:y=14:fontsize=20:fontcolor=white,"
V+="drawbox=x=0:y=48:w=260:h=852:color=0x252526:t=fill:enable='lt(t,20)+gte(t,34)',"
for i in 0 1 2 3; do
  name=$(echo "src/|  export.ts|  dialog.tsx|  settings.ts" | cut -d'|' -f$((i+1)))
  V+="drawtext=fontfile=$MONO:text='$name':x=20:y=$((80 + i*34)):fontsize=20:fontcolor=0xbbbbbb:enable='lt(t,20)+gte(t,34)',"
done
V+=$(code_line 'import { renderPdf } from "./pdf"' 80 0)
V+=$(code_line 'import { openDialog } from "./dialog"' 112 0)
V+=$(code_line "" 144 0)
V+=$(code_line "export async function exportInvoice(id) {" 176 0)
V+=$(code_line '  const dialog = openDialog("Export invoice as PDF")' 208 0)
V+=$(code_line "  const pdf = await renderPdf(id)" 240 2)
V+=$(code_line "  dialog.close()   // closes before the user can confirm" 272 3.5)
V+=$(code_line "  return pdf" 304 5)
V+=$(code_line "}" 336 5)
# Mouse cursor travels to the Export button, then to the language dropdown.
# (drawtext re-evaluates x/y on every frame; drawbox does not.)
CX="if(lt(t,6),800,if(lt(t,8.5),800+(t-6)/2.5*530,if(lt(t,24),1330,if(lt(t,25.5),1330-(t-24)/1.5*690,640))))"
CY="if(lt(t,6),500,if(lt(t,8.5),500-(t-6)/2.5*476,if(lt(t,24),24,if(lt(t,25.5),24+(t-24)/1.5*296,320))))"
CURSOR="drawtext=fontfile=$MONO:text='▲':x='$CX':y='$CY':fontsize=22:fontcolor=white:borderw=2:bordercolor=black"
# The bug: the dialog flickers for 0.6 s after the click, then disappears.
V+="drawbox=x=470:y=300:w=500:h=240:color=0xf3f3f3:t=fill:enable='between(t,9,9.6)*lt(mod(n,8),4)',"
V+="drawtext=fontfile=$SANS:text='Export invoice as PDF':x=520:y=340:fontsize=28:fontcolor=0x222222:enable='between(t,9,9.6)*lt(mod(n,8),4)',"
V+="drawbox=x=780:y=470:w=160:h=44:color=0x0e639c:t=fill:enable='between(t,9,9.6)*lt(mod(n,8),4)',"
# Settings page (light theme) from 20 s to 34 s; the language changes at 26 s.
V+="drawbox=x=0:y=48:w=1440:h=852:color=0xf7f7f7:t=fill:enable='between(t,20,34)',"
V+="drawtext=fontfile=$SANS:text='Settings':x=80:y=110:fontsize=44:fontcolor=0x111111:enable='between(t,20,34)',"
V+="drawtext=fontfile=$SANS:text='Language':x=80:y=250:fontsize=26:fontcolor=0x333333:enable='between(t,20,34)',"
V+="drawbox=x=80:y=300:w=420:h=48:color=0xdddddd:t=fill:enable='between(t,20,34)',"
V+="drawtext=fontfile=$SANS:text='English':x=96:y=312:fontsize=24:fontcolor=0x111111:enable='between(t,20,26)',"
V+="drawtext=fontfile=$SANS:text='Korean':x=96:y=312:fontsize=24:fontcolor=0x111111:enable='between(t,26,34)',"
# A list that scrolls (jerkily) from 34 s.
for i in $(seq 0 19); do
  Y="80+$((i * 40))-floor((t-34)*4)*40"
  V+="drawtext=fontfile=$MONO:text='invoice-$((1000 + i)).pdf     $((120 + i * 7)).00 EUR':x=300:y='$Y':fontsize=22:fontcolor=0xd4d4d4:enable='gte(t,34)*gte($Y,60)',"
done
V+="$CURSOR"

"$FF" -hide_banner -loglevel error -y \
  -f lavfi -i "$V" \
  -i "$TMP/v1.aiff" -i "$TMP/v2.aiff" -i "$TMP/v3.aiff" -i "$TMP/v4.aiff" \
  -filter_complex "[1:a]adelay=1000|1000[a1];[2:a]adelay=8500|8500[a2];[3:a]adelay=21000|21000[a3];[4:a]adelay=34500|34500[a4];[a1][a2][a3][a4]amix=inputs=4:normalize=0,apad[a]" \
  -map 0:v -map "[a]" -t 40 -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k \
  "$OUT_DIR/demo-screen.mp4"
echo "$OUT_DIR/demo-screen.mp4"

/**
 * A tiny 7-pixel-tall bitmap font, so timestamps can be burned into frames
 * without depending on system fonts or an ffmpeg build with libfreetype.
 */
const GLYPHS: Record<string, readonly string[]> = {
  "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
  "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
  "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
  "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
  "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
  "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
  "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
  "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
  "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
  "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
  ":": ["..", "##", "##", "..", "##", "##", ".."],
  ".": ["..", "..", "..", "..", "..", "##", "##"],
  "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
  "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
  "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
  "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
  " ": ["...", "...", "...", "...", "...", "...", "..."],
};

export const GLYPH_HEIGHT = 7;

export interface Canvas {
  data: Buffer;
  width: number;
  height: number;
}

export function textWidth(text: string, scale: number): number {
  let width = 0;
  for (const ch of text) width += (glyphFor(ch)[0]?.length ?? 0) * scale + scale;
  return Math.max(0, width - scale);
}

function glyphFor(ch: string): readonly string[] {
  return GLYPHS[ch] ?? GLYPHS[" "] ?? [];
}

export interface LabelStyle {
  scale: number;
  padding: number;
  /** 0..1 opacity of the black box behind the text. */
  boxOpacity: number;
}

/** Draws white text on a translucent black box whose top-left corner is (x, y). */
export function drawLabel(canvas: Canvas, text: string, x: number, y: number, style: LabelStyle): void {
  const boxW = textWidth(text, style.scale) + style.padding * 2;
  const boxH = GLYPH_HEIGHT * style.scale + style.padding * 2;
  shadeRect(canvas, { x, y, w: boxW, h: boxH }, style.boxOpacity);
  let penX = x + style.padding;
  const penY = y + style.padding;
  for (const ch of text) {
    const glyph = glyphFor(ch);
    drawGlyph(canvas, glyph, penX, penY, style.scale);
    penX += (glyph[0]?.length ?? 0) * style.scale + style.scale;
  }
}

function drawGlyph(canvas: Canvas, glyph: readonly string[], x: number, y: number, scale: number): void {
  glyph.forEach((row, gy) => {
    for (let gx = 0; gx < row.length; gx += 1) {
      if (row[gx] === "#") fillRect(canvas, { x: x + gx * scale, y: y + gy * scale, w: scale, h: scale }, [255, 255, 255]);
    }
  });
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export function fillRect(canvas: Canvas, rect: Rect, rgb: readonly [number, number, number]): void {
  const { x0, y0, x1, y1 } = clip(canvas, rect);
  for (let py = y0; py < y1; py += 1) {
    let offset = (py * canvas.width + x0) * 3;
    for (let px = x0; px < x1; px += 1) {
      canvas.data[offset] = rgb[0];
      canvas.data[offset + 1] = rgb[1];
      canvas.data[offset + 2] = rgb[2];
      offset += 3;
    }
  }
}

function shadeRect(canvas: Canvas, rect: Rect, opacity: number): void {
  const keep = 1 - Math.min(1, Math.max(0, opacity));
  const { x0, y0, x1, y1 } = clip(canvas, rect);
  for (let py = y0; py < y1; py += 1) {
    const start = (py * canvas.width + x0) * 3;
    const end = (py * canvas.width + x1) * 3;
    for (let offset = start; offset < end; offset += 1) {
      canvas.data[offset] = Math.round((canvas.data[offset] ?? 0) * keep);
    }
  }
}

function clip(canvas: Canvas, rect: Rect): { x0: number; y0: number; x1: number; y1: number } {
  return {
    x0: Math.max(0, Math.floor(rect.x)),
    y0: Math.max(0, Math.floor(rect.y)),
    x1: Math.min(canvas.width, Math.floor(rect.x + rect.w)),
    y1: Math.min(canvas.height, Math.floor(rect.y + rect.h)),
  };
}

export interface Ring {
  cx: number;
  cy: number;
  radius: number;
  thickness: number;
}

/** Draws a circle outline, clipped to `clipRect`. Used to mark where a click happened. */
export function drawRing(canvas: Canvas, ring: Ring, rgb: readonly [number, number, number], clipRect: Rect): void {
  const { x0, y0, x1, y1 } = clip(canvas, clipRect);
  const outer = ring.radius + ring.thickness / 2;
  const inner = Math.max(0, ring.radius - ring.thickness / 2);
  const top = Math.max(y0, Math.floor(ring.cy - outer));
  const bottom = Math.min(y1, Math.ceil(ring.cy + outer));
  const left = Math.max(x0, Math.floor(ring.cx - outer));
  const right = Math.min(x1, Math.ceil(ring.cx + outer));
  for (let py = top; py < bottom; py += 1) {
    for (let px = left; px < right; px += 1) {
      const d = Math.hypot(px + 0.5 - ring.cx, py + 0.5 - ring.cy);
      if (d < inner || d > outer) continue;
      const offset = (py * canvas.width + px) * 3;
      canvas.data[offset] = rgb[0];
      canvas.data[offset + 1] = rgb[1];
      canvas.data[offset + 2] = rgb[2];
    }
  }
}

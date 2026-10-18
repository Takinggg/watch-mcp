import { drawLabel, drawRing, fillRect, GLYPH_HEIGHT, type Canvas } from "./font.ts";

export interface TileGrid {
  cols: number;
  rows: number;
  tileW: number;
  tileH: number;
  gutter: number;
  /** Height of the caption strip drawn above each tile (the label never covers the picture). */
  labelH: number;
}

export interface SheetLayout extends TileGrid {
  width: number;
  height: number;
}

export interface GridOptions {
  /** Maximum tiles on one sheet. */
  perSheet: number;
  /** Longest allowed edge of a sheet, gutters included. */
  maxEdge: number;
  gutter: number;
}

/** Font scale of tile captions: 7-pixel glyphs drawn at 2x (14 px tall). */
export const LABEL_SCALE = 2;
const LABEL_PAD = 2;
export const LABEL_HEIGHT = GLYPH_HEIGHT * LABEL_SCALE + LABEL_PAD * 2;

/**
 * Picks the grid (cols x rows, cols * rows = perSheet exactly) that gives the
 * largest tiles for this aspect ratio while keeping the sheet within maxEdge.
 */
export function chooseGrid(aspect: number, opts: GridOptions): TileGrid {
  if (!(aspect > 0) || opts.perSheet < 1) throw new Error("chooseGrid: aspect and perSheet must be positive");
  let best: TileGrid | null = null;
  for (let cols = 1; cols <= opts.perSheet; cols += 1) {
    if (opts.perSheet % cols !== 0) continue;
    const rows = opts.perSheet / cols;
    const byWidth = (opts.maxEdge - (cols + 1) * opts.gutter) / (cols * aspect);
    const byHeight = (opts.maxEdge - (rows + 1) * opts.gutter - rows * LABEL_HEIGHT) / rows;
    const tileH = Math.floor(Math.min(byWidth, byHeight) / 2) * 2;
    const tileW = Math.floor((tileH * aspect) / 2) * 2;
    if (tileH < 2 || tileW < 2) continue;
    if (!best || tileW * tileH > best.tileW * best.tileH) {
      best = { cols, rows, tileW, tileH, gutter: opts.gutter, labelH: LABEL_HEIGHT };
    }
  }
  if (!best) throw new Error("chooseGrid: no grid fits");
  return best;
}

/** Layout for a sheet holding `count` tiles of the grid's tile size (the last sheet may be smaller). */
export function layoutSheet(grid: TileGrid, count: number): SheetLayout {
  if (count < 1) throw new Error("layoutSheet: count must be >= 1");
  let cols = Math.min(grid.cols, count);
  let rows = Math.ceil(count / cols);
  let bestEmpty = cols * rows - count;
  for (let c = 1; c <= Math.min(grid.cols, count); c += 1) {
    const r = Math.ceil(count / c);
    if (r > grid.rows) continue;
    const empty = c * r - count;
    if (empty < bestEmpty || (empty === bestEmpty && c > cols)) {
      cols = c;
      rows = r;
      bestEmpty = empty;
    }
  }
  const width = cols * grid.tileW + (cols + 1) * grid.gutter;
  const height = rows * (grid.tileH + grid.labelH) + (rows + 1) * grid.gutter;
  return { ...grid, cols, rows, width: width + (width % 2), height: height + (height % 2) };
}

export interface SheetTile {
  /** RGB24 pixels, exactly tileW x tileH. */
  rgb: Buffer;
  label: string;
  /** Click positions to circle, as fractions of the tile (0..1 from the top-left). */
  marks?: ReadonlyArray<{ x: number; y: number }> | undefined;
}

const BACKGROUND: readonly [number, number, number] = [24, 24, 24];

/** Composes tiles row by row into one RGB24 sheet, each with its caption strip on top. */
export function composeSheet(layout: SheetLayout, tiles: readonly SheetTile[]): Canvas {
  const canvas: Canvas = { data: Buffer.alloc(layout.width * layout.height * 3), width: layout.width, height: layout.height };
  fillRect(canvas, { x: 0, y: 0, w: layout.width, h: layout.height }, BACKGROUND);
  tiles.forEach((tile, i) => {
    const col = i % layout.cols;
    const row = Math.floor(i / layout.cols);
    if (row >= layout.rows) throw new Error("composeSheet: more tiles than cells");
    const x = layout.gutter + col * (layout.tileW + layout.gutter);
    const y = layout.gutter + row * (layout.tileH + layout.labelH + layout.gutter);
    fillRect(canvas, { x, y, w: layout.tileW, h: layout.labelH }, [0, 0, 0]);
    drawLabel(canvas, tile.label, x, y, { scale: LABEL_SCALE, padding: LABEL_PAD, boxOpacity: 1 });
    const picture = { x, y: y + layout.labelH, w: layout.tileW, h: layout.tileH };
    blit(canvas, tile.rgb, picture);
    for (const mark of tile.marks ?? []) markClick(canvas, picture, mark);
  });
  return canvas;
}

/** A yellow ring with a dark edge, visible on light and dark pictures. */
function markClick(canvas: Canvas, picture: { x: number; y: number; w: number; h: number }, mark: { x: number; y: number }): void {
  const cx = picture.x + mark.x * picture.w;
  const cy = picture.y + mark.y * picture.h;
  const radius = Math.max(7, picture.w * 0.035);
  drawRing(canvas, { cx, cy, radius, thickness: 5 }, [0, 0, 0], picture);
  drawRing(canvas, { cx, cy, radius, thickness: 2.5 }, [255, 214, 0], picture);
}

function blit(canvas: Canvas, rgb: Buffer, rect: { x: number; y: number; w: number; h: number }): void {
  const rowBytes = rect.w * 3;
  if (rgb.length !== rowBytes * rect.h) throw new Error("blit: tile buffer has the wrong size");
  for (let row = 0; row < rect.h; row += 1) {
    const target = ((rect.y + row) * canvas.width + rect.x) * 3;
    rgb.copy(canvas.data, target, row * rowBytes, (row + 1) * rowBytes);
  }
}

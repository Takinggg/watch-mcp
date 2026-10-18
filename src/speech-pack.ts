/** 16 kHz mono signed 16-bit PCM, what Whisper expects. */
export const SAMPLE_RATE = 16_000;

export interface Piece {
  /** Start and end in the packed audio (s). */
  packedStart: number;
  packedEnd: number;
  /** Start in the original audio (s). */
  originalStart: number;
}

const PAD = 0.2;
const GAP = 0.3;

/** Concatenates the speech regions (padded by 0.2 s, 0.3 s of silence between them). */
export function packSpeech(pcm: Buffer, regions: ReadonlyArray<readonly [number, number]>, audioSeconds: number): { audio: Buffer; pieces: Piece[] } {
  const merged: Array<[number, number]> = [];
  for (const [s, e] of regions) {
    const start = Math.max(0, s - PAD);
    const end = Math.min(audioSeconds, e + PAD);
    const last = merged.at(-1);
    if (last && start <= last[1]) last[1] = Math.max(last[1], end);
    else if (end > start) merged.push([start, end]);
  }
  const silence = Buffer.alloc(Math.round(GAP * SAMPLE_RATE) * 2);
  const chunks: Buffer[] = [];
  const pieces: Piece[] = [];
  let packed = 0;
  for (const [start, end] of merged) {
    const from = Math.floor(start * SAMPLE_RATE) * 2;
    const to = Math.min(pcm.length, Math.floor(end * SAMPLE_RATE) * 2);
    if (pieces.length > 0) {
      chunks.push(silence);
      packed += GAP;
    }
    chunks.push(pcm.subarray(from, to));
    const length = (to - from) / 2 / SAMPLE_RATE;
    pieces.push({ packedStart: packed, packedEnd: packed + length, originalStart: from / 2 / SAMPLE_RATE });
    packed += length;
  }
  return { audio: Buffer.concat(chunks), pieces };
}

/** Maps a time in the packed audio back to the original; times in a gap snap to the nearest piece. */
export function toOriginalTime(pieces: readonly Piece[], t: number): number {
  let best: Piece | undefined;
  for (const piece of pieces) {
    if (t >= piece.packedStart && t <= piece.packedEnd) return piece.originalStart + (t - piece.packedStart);
    if (t > piece.packedEnd) best = piece;
  }
  if (!best) return pieces[0]?.originalStart ?? 0;
  return best.originalStart + (best.packedEnd - best.packedStart);
}

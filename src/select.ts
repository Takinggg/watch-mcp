/**
 * Adaptive keyframe selection.
 *
 * Each analysis sample is a small grayscale signature of a frame.
 *
 * 1. Activity episodes: stretches where the picture keeps changing (typing a
 *    line, a dialog flashing, a scene cut, a scroll), merged when separated by
 *    a short pause. Each episode gets one representative: its most novel frame
 *    compared with the picture just before it. So short events, even a flicker
 *    that reverts, are shown. If there are more episodes than budget, the
 *    strongest ones win.
 * 2. The rest of the budget goes to continuous change: walking the video, a
 *    frame is kept when it differs from the last kept frame by at least `need`
 *    pixels, with `need` binary-searched to fit the budget. Busy parts get many
 *    frames, static parts none, and gradual changes (scrolls, pans) accumulate.
 */

export interface SelectOptions {
  /** Maximum number of frames to return (>= 1). */
  budget: number;
  /** Gray-level difference above which a pixel counts as changed. */
  pixelThreshold?: number;
  /** Activity runs separated by at most this many quiet samples form one episode (default 1). */
  mergeGapSamples?: number;
  /** Samples that must be kept (e.g. the moment of each recorded click); at most half the budget. */
  forced?: readonly number[];
}

export interface SelectedFrame {
  /** Index into the signature list. */
  index: number;
  /** Share of pixels (0..1) that differ from the previous kept frame; 0 for the first one. */
  change: number;
  /** True when this frame follows a hard cut (most of the picture changed in one sample). */
  cut: boolean;
  /** Last sample index that still looks the same as this frame. */
  sameUntil: number;
}

const DEFAULT_PIXEL_THRESHOLD = 10;
const CUT_SHARE = 0.4;

interface Ctx {
  sigs: readonly Uint8Array[];
  threshold: number;
  size: number;
  /** Changed pixels needed to call two samples different. */
  minNeed: number;
}

export function selectKeyframes(sigs: readonly Uint8Array[], opts: SelectOptions): SelectedFrame[] {
  const n = sigs.length;
  if (n === 0) return [];
  const size = (sigs[0] as Uint8Array).length;
  if (sigs.some((sig) => sig.length !== size)) throw new Error("selectKeyframes: signatures differ in size");
  const budget = Math.max(1, Math.floor(opts.budget));
  // 0.03 % of the signature: a short word changing in a 1440 px wide screen recording still counts.
  const ctx: Ctx = { sigs, threshold: opts.pixelThreshold ?? DEFAULT_PIXEL_THRESHOLD, size, minNeed: Math.max(2, Math.ceil(size * 0.0003)) };

  const steps = consecutiveChanges(ctx);
  // Reserve one slot so the final picture can always be shown.
  const target = Math.max(1, budget - 1);
  const episodes = activityEpisodes(ctx, steps, Math.max(0, opts.mergeGapSamples ?? 1));
  const forced = spread(uniqueSorted((opts.forced ?? []).filter((i) => i > 0 && i < n)), Math.floor((target - 1) / 2));
  const seeds = uniqueSorted([...forced, ...strongest(episodes.filter((e) => !forced.includes(e.rep)), target - 1 - forced.length)]);
  const picked = fillBudget(ctx, seeds, target);
  const last = n - 1;
  const lastPicked = picked.at(-1) ?? 0;
  if (lastPicked !== last && picked.length < budget && diff(ctx, lastPicked, last, ctx.minNeed) >= ctx.minNeed) picked.push(last);
  return annotate(ctx, picked, steps);
}

/** steps[k] = changed pixels between sample k-1 and k (steps[0] = 0). */
function consecutiveChanges(ctx: Ctx): number[] {
  return ctx.sigs.map((_, k) => (k === 0 ? 0 : diff(ctx, k - 1, k, Number.POSITIVE_INFINITY)));
}

interface Episode {
  /** Most novel sample of the episode. */
  rep: number;
  /** Changed pixels between the picture before the episode and `rep`. */
  score: number;
}

/**
 * Groups changing samples into episodes (runs of change separated by at most
 * `mergeGap` quiet samples) and picks, for each, the sample that differs most
 * from the picture just before the episode started.
 */
function activityEpisodes(ctx: Ctx, steps: readonly number[], mergeGap: number): Episode[] {
  const episodes: Episode[] = [];
  let k = 1;
  while (k < steps.length) {
    if ((steps[k] as number) < ctx.minNeed) {
      k += 1;
      continue;
    }
    const before = k - 1;
    const best: Episode = { rep: k, score: -1 };
    let quiet = 0;
    while (k < steps.length && quiet <= mergeGap) {
      if ((steps[k] as number) >= ctx.minNeed) {
        quiet = 0;
        const score = diff(ctx, before, k, Number.POSITIVE_INFINITY);
        if (score >= best.score) {
          best.rep = k;
          best.score = score;
        }
      } else {
        quiet += 1;
      }
      k += 1;
    }
    episodes.push(best);
  }
  return episodes;
}

/** Representatives of the `limit` strongest episodes, in time order. */
function strongest(episodes: readonly Episode[], limit: number): number[] {
  if (limit <= 0) return [];
  const chosen = episodes.length <= limit ? [...episodes] : [...episodes].sort((a, b) => b.score - a.score).slice(0, limit);
  return chosen.map((e) => e.rep).sort((a, b) => a - b);
}

function uniqueSorted(values: readonly number[]): number[] {
  return [...new Set(values)].sort((a, b) => a - b);
}

/** At most `limit` values, evenly spread over the list. */
function spread(values: readonly number[], limit: number): number[] {
  if (values.length <= limit) return [...values];
  if (limit <= 0) return [];
  return Array.from({ length: limit }, (_, i) => values[Math.floor((i * values.length) / limit)] as number);
}

/** Seeds plus greedy picks, with the largest pick count that fits `target`. */
function fillBudget(ctx: Ctx, seeds: readonly number[], target: number): number[] {
  const seedSet = new Set(seeds);
  if (greedy(ctx, seedSet, ctx.minNeed).length <= target) return greedy(ctx, seedSet, ctx.minNeed);
  let lo = ctx.minNeed;
  let hi = ctx.size + 1;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (greedy(ctx, seedSet, mid).length <= target) hi = mid;
    else lo = mid + 1;
  }
  return greedy(ctx, seedSet, lo).slice(0, target);
}

/** Keeps sample 0, every seed, and any sample differing from the last kept one by `need` pixels. */
function greedy(ctx: Ctx, seeds: ReadonlySet<number>, need: number): number[] {
  const kept = [0];
  let last = 0;
  for (let k = 1; k < ctx.sigs.length; k += 1) {
    if (seeds.has(k) || diff(ctx, last, k, need) >= need) {
      kept.push(k);
      last = k;
    }
  }
  return kept;
}

/** Counts pixels whose difference exceeds the threshold, stopping early once `stopAt` is reached. */
export function countChangedPixels(a: Uint8Array, b: Uint8Array, threshold: number, stopAt: number): number {
  let count = 0;
  for (let i = 0; i < a.length; i += 1) {
    const d = (a[i] as number) - (b[i] as number);
    if (d > threshold || d < -threshold) {
      count += 1;
      if (count >= stopAt) return count;
    }
  }
  return count;
}

function diff(ctx: Ctx, i: number, j: number, stopAt: number): number {
  return countChangedPixels(ctx.sigs[i] as Uint8Array, ctx.sigs[j] as Uint8Array, ctx.threshold, stopAt);
}

function annotate(ctx: Ctx, picked: readonly number[], steps: readonly number[]): SelectedFrame[] {
  return picked.map((index, p) => {
    const prev = p > 0 ? (picked[p - 1] as number) : -1;
    const change = prev < 0 ? 0 : diff(ctx, prev, index, Number.POSITIVE_INFINITY) / ctx.size;
    const nextPicked = p + 1 < picked.length ? (picked[p + 1] as number) : ctx.sigs.length;
    let sameUntil = index;
    while (sameUntil + 1 < nextPicked && diff(ctx, index, sameUntil + 1, ctx.minNeed) < ctx.minNeed) sameUntil += 1;
    return { index, change, cut: (steps[index] as number) / ctx.size >= CUT_SHARE, sameUntil };
  });
}

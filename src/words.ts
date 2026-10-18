/** A timed piece of transcript. Times are seconds on the video clock. */
export interface TimedText {
  start: number;
  end: number;
  text: string;
}

/**
 * Whisper token pieces (with token timestamps and max length 1) come out as
 * " Je", " vous", " l", "'", "ex", "port", ".". A leading space starts a new word;
 * anything else (subword pieces, apostrophes, punctuation) joins the previous word.
 */
export function tokensToWords(tokens: readonly TimedText[]): TimedText[] {
  const words: TimedText[] = [];
  for (const token of tokens) {
    if (token.text.length === 0) continue;
    const last = words.at(-1);
    const startsWord = /^\s/.test(token.text) || last === undefined;
    if (startsWord) {
      const text = token.text.trim();
      if (text.length > 0) words.push({ start: token.start, end: Math.max(token.start, token.end), text });
    } else if (last) {
      last.text += token.text.trim();
      last.end = Math.max(last.end, token.end);
    }
  }
  return words;
}

const SENTENCE_END = /[.!?。！？]["')\]]*$/;
const PAUSE_SPLIT = 1.0;
const MAX_WORDS = 30;

/** Groups words into readable segments: at sentence ends, pauses over 1 s, or 30 words. */
export function wordsToSegments(words: readonly TimedText[]): TimedText[] {
  const segments: TimedText[] = [];
  let current: TimedText[] = [];
  const flush = (): void => {
    const first = current[0];
    const last = current.at(-1);
    if (first && last) segments.push({ start: first.start, end: last.end, text: current.map((w) => w.text).join(" ") });
    current = [];
  };
  words.forEach((word, i) => {
    current.push(word);
    const next = words[i + 1];
    const pause = next ? next.start - word.end : 0;
    if (!next || SENTENCE_END.test(word.text) || pause > PAUSE_SPLIT || current.length >= MAX_WORDS) flush();
  });
  return segments;
}

import { WatchError } from "./errors.ts";

/**
 * Parses a timestamp given as seconds (number or "12.5" / "12.5s")
 * or as a clock string ("1:23", "01:23.4", "1:02:03.25").
 */
export function parseTime(input: number | string, field: string): number {
  if (typeof input === "number") return checkFinite(input, field);
  const text = input.trim().toLowerCase().replace(/s$/, "");
  if (/^\d+(\.\d+)?$/.test(text)) return checkFinite(Number(text), field);
  const match = /^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)$/.exec(text);
  if (!match) {
    throw new WatchError("BAD_ARGUMENT", `${field} must be seconds (e.g. 83.5) or a timestamp like 01:23.5.`);
  }
  const hours = match[1] === undefined ? 0 : Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  if (minutes >= 60 && match[1] !== undefined) {
    throw new WatchError("BAD_ARGUMENT", `${field}: minutes must be below 60 when hours are given.`);
  }
  return checkFinite(hours * 3600 + minutes * 60 + seconds, field);
}

function checkFinite(value: number, field: string): number {
  if (!Number.isFinite(value) || value < 0) {
    throw new WatchError("BAD_ARGUMENT", `${field} must be a finite, non-negative time.`);
  }
  return value;
}

/** Formats seconds as mm:ss.d (or h:mm:ss.d when `withHours`), with `decimals` digits. */
export function formatTime(seconds: number, decimals = 1, withHours = false): string {
  const safe = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  const scale = 10 ** decimals;
  const totalUnits = Math.round(safe * scale);
  const units = totalUnits % scale;
  const totalSeconds = Math.floor(totalUnits / scale);
  const s = totalSeconds % 60;
  const totalMinutes = Math.floor(totalSeconds / 60);
  const fraction = decimals > 0 ? `.${String(units).padStart(decimals, "0")}` : "";
  if (withHours || totalMinutes >= 60) {
    const h = Math.floor(totalMinutes / 60);
    const m = totalMinutes % 60;
    return `${h}:${pad2(m)}:${pad2(s)}${fraction}`;
  }
  return `${pad2(totalMinutes)}:${pad2(s)}${fraction}`;
}

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

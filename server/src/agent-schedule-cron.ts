export function validateScheduleTimeZone(timeZone: string | undefined): string {
  const value = timeZone?.trim() ?? "";
  if (!value) throw new Error("Schedule timeZone is required");
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(new Date(0));
  } catch {
    throw new Error(`Schedule timeZone is invalid: ${value}`);
  }
  return value;
}

export function validateCronExpression(expression: string | undefined): string {
  const value = expression?.trim() ?? "";
  if (!value) throw new Error("Schedule cron trigger requires an expression");
  parseCronExpression(value);
  return value;
}

interface CronField {
  values: Set<number>;
  wildcard: boolean;
}

interface CronSpec {
  minute: CronField;
  hour: CronField;
  dayOfMonth: CronField;
  month: CronField;
  dayOfWeek: CronField;
}

export function cronMatchesNow(expression: string, timeZone: string, minuteStart: number): boolean {
  return specMatches(parseCronExpression(expression), zonedDateParts(minuteStart, timeZone));
}

function specMatches(spec: CronSpec, parts: ZonedParts): boolean {
  if (!spec.minute.values.has(parts.minute)) return false;
  if (!spec.hour.values.has(parts.hour)) return false;
  if (!spec.month.values.has(parts.month)) return false;
  return dayMatches(spec, parts.dayOfMonth, parts.dayOfWeek);
}

/** Standard cron: with both day fields restricted, either may match; otherwise both must. */
function dayMatches(spec: CronSpec, dayOfMonth: number, dayOfWeek: number): boolean {
  const dayOfMonthMatches = spec.dayOfMonth.values.has(dayOfMonth);
  const dayOfWeekMatches = spec.dayOfWeek.values.has(dayOfWeek);
  if (!spec.dayOfMonth.wildcard && !spec.dayOfWeek.wildcard) {
    return dayOfMonthMatches || dayOfWeekMatches;
  }
  return dayOfMonthMatches && dayOfWeekMatches;
}

const MS_PER_DAY = 86_400_000;

/**
 * The minutes a cron trigger is due in `[from, to)`, oldest first, at most `limit`.
 *
 * The runner's rule, so the calendar and the runner agree: a minute is due when
 * `cronMatchesNow` matches it and it is not before `createdAt`; a spring-forward gap's
 * wall-clock minutes never occur, and a fall-back hour's repeat is due only when its first
 * occurrence came before `createdAt` (`earlierRepeatedWallClockMinute`). It walks the zone's
 * calendar days and the expression's hour and minute sets rather than every minute, so a
 * month costs a few hundred zone lookups for a daily trigger.
 */
export function cronOccurrences(
  expression: string,
  timeZone: string,
  range: { from: number; to: number; createdAt: number; limit: number },
): { at: number[]; truncated: boolean } {
  const spec = parseCronExpression(expression);
  const start = Math.ceil(Math.max(range.from, range.createdAt) / MS_PER_MINUTE) * MS_PER_MINUTE;
  const at: number[] = [];
  if (start >= range.to || range.limit <= 0) return { at, truncated: false };
  const hours = [...spec.hour.values].sort((a, b) => a - b);
  const minutes = [...spec.minute.values].sort((a, b) => a - b);
  const first = zonedDateParts(start, timeZone);
  const last = zonedDateParts(range.to - 1, timeZone);
  const lastDay = Date.UTC(last.year, last.month - 1, last.dayOfMonth);
  for (
    let day = Date.UTC(first.year, first.month - 1, first.dayOfMonth);
    day <= lastDay;
    day += MS_PER_DAY
  ) {
    const date = new Date(day);
    const month = date.getUTCMonth() + 1;
    if (!spec.month.values.has(month)) continue;
    if (!dayMatches(spec, date.getUTCDate(), date.getUTCDay())) continue;
    const due: number[] = [];
    for (const hour of hours) {
      for (const minute of minutes) {
        for (const instant of wallClockInstants(
          timeZone,
          day + hour * 3_600_000 + minute * MS_PER_MINUTE,
        )) {
          if (instant < start || instant >= range.to) continue;
          // The runner's own test of the minute, and its fall-back rule.
          if (!specMatches(spec, zonedDateParts(instant, timeZone))) continue;
          if (earlierRepeatedWallClockMinute(timeZone, instant, range.createdAt) !== undefined) {
            continue;
          }
          due.push(instant);
        }
      }
    }
    // A fall-back day can list a repeated hour's minutes out of order.
    due.sort((a, b) => a - b);
    for (const instant of due) {
      if (at.length === range.limit) return { at, truncated: true };
      at.push(instant);
    }
  }
  return { at, truncated: false };
}

/**
 * The UTC instants whose wall clock in `timeZone` reads `naive` (a wall-clock time written as
 * if it were UTC): none in a spring-forward gap, two in a fall-back hour. A zone's offset
 * changes at most once in two days, so the offsets a day either side cover every reading.
 */
function wallClockInstants(timeZone: string, naive: number): number[] {
  const instants = new Set<number>();
  for (const probe of [naive - MS_PER_DAY, naive, naive + MS_PER_DAY]) {
    const candidate = naive - zoneOffset(timeZone, probe);
    const parts = zonedDateParts(candidate, timeZone);
    const reads = Date.UTC(parts.year, parts.month - 1, parts.dayOfMonth, parts.hour, parts.minute);
    if (reads === naive) instants.add(candidate);
  }
  return [...instants].sort((a, b) => a - b);
}

/** Wall clock minus UTC at `ms`, to the minute. */
function zoneOffset(timeZone: string, ms: number): number {
  const minute = Math.floor(ms / MS_PER_MINUTE) * MS_PER_MINUTE;
  const parts = zonedDateParts(minute, timeZone);
  return Date.UTC(parts.year, parts.month - 1, parts.dayOfMonth, parts.hour, parts.minute) - minute;
}

// DST shifts are 30, 60, or 120 minutes. When the clock falls back by N minutes, the
// wall-clock minute at UTC instant t also occurred at t - N.
const DST_FALL_BACK_SHIFT_MINUTES = [30, 60, 120];
const MS_PER_MINUTE = 60_000;

/**
 * Returns the UTC start of an earlier occurrence of the same zoned wall-clock minute within
 * the last DST shift (a repeated fall-back hour), or undefined when the minute is not repeated
 * or the earlier occurrence is before `notBefore`.
 */
export function earlierRepeatedWallClockMinute(
  timeZone: string,
  minuteStart: number,
  notBefore: number,
): number | undefined {
  const parts = zonedDateParts(minuteStart, timeZone);
  for (const shift of DST_FALL_BACK_SHIFT_MINUTES) {
    const earlier = minuteStart - shift * MS_PER_MINUTE;
    if (earlier < notBefore) continue;
    const earlierParts = zonedDateParts(earlier, timeZone);
    if (
      earlierParts.minute === parts.minute &&
      earlierParts.hour === parts.hour &&
      earlierParts.dayOfMonth === parts.dayOfMonth &&
      earlierParts.month === parts.month
    ) {
      return earlier;
    }
  }
  return undefined;
}

function parseCronExpression(expression: string): CronSpec {
  const fields = expression.trim().split(/\s+/).filter(Boolean);
  const normalized = fields.length === 6 ? fields.slice(1) : fields;
  if (normalized.length !== 5) {
    throw new Error("Schedule cron expression must have 5 fields, or 6 fields with seconds first");
  }
  return {
    minute: parseCronField(normalized[0] ?? "", 0, 59),
    hour: parseCronField(normalized[1] ?? "", 0, 23),
    dayOfMonth: parseCronField(normalized[2] ?? "", 1, 31),
    month: parseCronField(normalized[3] ?? "", 1, 12),
    dayOfWeek: parseCronField(normalized[4] ?? "", 0, 7, { normalizeSevenToZero: true }),
  };
}

function parseCronField(
  raw: string,
  min: number,
  max: number,
  opts: { normalizeSevenToZero?: boolean } = {},
): CronField {
  const text = raw.trim();
  if (!text) throw new Error("Schedule cron field is empty");
  const wildcard = text === "*" || text.startsWith("*/");
  const values = new Set<number>();
  for (const part of text.split(",")) {
    addCronPart(values, part.trim(), min, max, opts);
  }
  if (values.size === 0) throw new Error(`Schedule cron field has no values: ${raw}`);
  return { values, wildcard };
}

function addCronPart(
  values: Set<number>,
  raw: string,
  min: number,
  max: number,
  opts: { normalizeSevenToZero?: boolean },
): void {
  if (!raw) throw new Error("Schedule cron field contains an empty segment");
  const [rangeText, stepText] = raw.split("/");
  const step = stepText === undefined ? 1 : Number.parseInt(stepText, 10);
  if (!Number.isSafeInteger(step) || step <= 0) {
    throw new Error(`Schedule cron step must be a positive integer: ${raw}`);
  }

  const [start, end] = parseCronRange(rangeText ?? "", min, max);
  for (let value = start; value <= end; value += step) {
    values.add(normalizeCronValue(value, opts));
  }
}

function parseCronRange(raw: string, min: number, max: number): [number, number] {
  if (raw === "*") return [min, max];
  if (raw.includes("-")) {
    const [startText, endText] = raw.split("-");
    const start = parseCronNumber(startText ?? "", min, max);
    const end = parseCronNumber(endText ?? "", min, max);
    if (end < start) throw new Error(`Schedule cron range is inverted: ${raw}`);
    return [start, end];
  }
  const value = parseCronNumber(raw, min, max);
  return [value, value];
}

function parseCronNumber(raw: string, min: number, max: number): number {
  if (!/^\d+$/.test(raw)) throw new Error(`Schedule cron field value must be numeric: ${raw}`);
  const value = Number.parseInt(raw, 10);
  if (value < min || value > max) {
    throw new Error(`Schedule cron field value ${value} is outside ${min}-${max}`);
  }
  return value;
}

function normalizeCronValue(value: number, opts: { normalizeSevenToZero?: boolean }): number {
  return opts.normalizeSevenToZero && value === 7 ? 0 : value;
}

interface ZonedParts {
  minute: number;
  hour: number;
  dayOfMonth: number;
  month: number;
  year: number;
  dayOfWeek: number;
}

/** One formatter per zone: building an `Intl.DateTimeFormat` costs far more than using one. */
const zonedFormatters = new Map<string, Intl.DateTimeFormat>();

function zonedDateParts(ms: number, timeZone: string): ZonedParts {
  let formatter = zonedFormatters.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-US", {
      timeZone,
      weekday: "short",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      hourCycle: "h23",
    });
    zonedFormatters.set(timeZone, formatter);
  }
  const parts = Object.fromEntries(
    formatter.formatToParts(new Date(ms)).map((part) => [part.type, part.value]),
  );
  const weekday = weekdayToNumber(parts.weekday ?? "");
  return {
    minute: Number.parseInt(parts.minute ?? "0", 10),
    hour: Number.parseInt(parts.hour ?? "0", 10),
    dayOfMonth: Number.parseInt(parts.day ?? "1", 10),
    month: Number.parseInt(parts.month ?? "1", 10),
    year: Number.parseInt(parts.year ?? "1970", 10),
    dayOfWeek: weekday,
  };
}

function weekdayToNumber(value: string): number {
  switch (value) {
    case "Sun":
      return 0;
    case "Mon":
      return 1;
    case "Tue":
      return 2;
    case "Wed":
      return 3;
    case "Thu":
      return 4;
    case "Fri":
      return 5;
    case "Sat":
      return 6;
    default:
      throw new Error(`Unsupported weekday from Intl: ${value}`);
  }
}

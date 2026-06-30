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
  const spec = parseCronExpression(expression);
  const parts = zonedDateParts(minuteStart, timeZone);
  if (!spec.minute.values.has(parts.minute)) return false;
  if (!spec.hour.values.has(parts.hour)) return false;
  if (!spec.month.values.has(parts.month)) return false;

  const dayOfMonthMatches = spec.dayOfMonth.values.has(parts.dayOfMonth);
  const dayOfWeekMatches = spec.dayOfWeek.values.has(parts.dayOfWeek);
  if (!spec.dayOfMonth.wildcard && !spec.dayOfWeek.wildcard) {
    return dayOfMonthMatches || dayOfWeekMatches;
  }
  return dayOfMonthMatches && dayOfWeekMatches;
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

function zonedDateParts(
  ms: number,
  timeZone: string,
): {
  minute: number;
  hour: number;
  dayOfMonth: number;
  month: number;
  dayOfWeek: number;
} {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    hourCycle: "h23",
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(new Date(ms)).map((part) => [part.type, part.value]),
  );
  const weekday = weekdayToNumber(parts.weekday ?? "");
  return {
    minute: Number.parseInt(parts.minute ?? "0", 10),
    hour: Number.parseInt(parts.hour ?? "0", 10),
    dayOfMonth: Number.parseInt(parts.day ?? "1", 10),
    month: Number.parseInt(parts.month ?? "1", 10),
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

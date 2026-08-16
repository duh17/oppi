export const COLD_SAMPLES = 30;
export const WARM_REST_SAMPLES = 200;
export const WEBSOCKET_SAMPLES = 200;
export const RECONNECT_SAMPLES = 20;
export const TRANSFER_SAMPLES = 5;
export const TRANSFER_SIZES = [1, 10, 50].map((mib) => mib * 1024 * 1024);

export type NumericSummary = {
  count: number;
  min: number;
  max: number;
  mean: number;
  p50: number;
  p95: number;
};

export type TimedSample = {
  sample: number;
  durationMs: number;
};

export type TransferSample = TimedSample & {
  direction: "upload" | "download";
  sizeBytes: number;
  throughputMbps: number;
};

function round(value: number, digits = 6): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

export function summarize(values: number[]): NumericSummary {
  if (values.length === 0) throw new Error("Cannot summarize an empty sample set");
  const sorted = [...values].sort((left, right) => left - right);
  const percentile = (p: number): number => sorted[Math.ceil(p * sorted.length) - 1] ?? sorted[0];
  return {
    count: values.length,
    min: round(sorted[0]),
    max: round(sorted[sorted.length - 1]),
    mean: round(values.reduce((total, value) => total + value, 0) / values.length),
    p50: round(percentile(0.5)),
    p95: round(percentile(0.95)),
  };
}

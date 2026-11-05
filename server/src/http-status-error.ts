/**
 * An error that already knows its HTTP status. Route handlers answer it with `status` and
 * `message` (`answerStatusError` in `routes/http.ts`). Subclasses exist so logs and telemetry
 * keep a readable `name`, which defaults to the subclass name.
 */
export class HttpStatusError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = new.target.name;
  }
}

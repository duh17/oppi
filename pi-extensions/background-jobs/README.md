# background-jobs

Reference Pi extension. Not a product feature. Copy it if you want long shell commands to leave the foreground and come back as a follow-up.

Bash waits 15 seconds. If the command is still running, it becomes a background job and a composer pill shows it. In Oppi, tap a job row in the pill's drawer to see that job's live output tail, colors and progress redraws included. The tail refreshes with the widget (at most every 400 ms) and is display only; the model still gets output once, in the batched result. Finished results are batched at the next safe model boundary, or sent once when the session is idle. A stop does not wake the model just to acknowledge them. A trailing `&` backgrounds immediately. Polling a running job is blocked.

In an Oppi auto-stop session, when the agent finishes its reply while jobs are still running, the session stays busy until a result arrives. The result continues the run without polling or model requests during the wait. This prevents auto-stop from ending the session before the job finishes. Stop interrupts the wait; queued steering and follow-up messages typed by the user can also continue the run. Custom follow-ups from other extensions, such as a supervised subagent's settlement, cannot end the wait because Pi does not report them to extensions; they run when the wait ends.

Other Oppi sessions do not hold the turn. The agent settles while jobs run, results start a new turn when they arrive, and other extensions' follow-ups start a turn right away. Oppi's idle timeout applies either way. The first time a turn would end with a job running, the extension runs `oppi session get <id> --json` once and remembers `launch.autoStop` for the rest of the session. It never polls. If the lookup fails (plain Pi, no `oppi` CLI, or a session Oppi does not know), it holds, as before.

In an auto-stop session, a server or watcher that never exits keeps the session busy. Cancel the job or stop the session when you no longer need it. This extension does not provide a detached-job mode.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./pi-extensions/background-jobs
```

Then ask for a command that should keep running, or call the `background_job` tool with `start`.

## Server-Durable implementation

`durable.ts` uses conversation-owned background tasks and the reporter pattern
from pi-durable's `test/examples/23-subagent-background.ts`. A stable request ID
makes follow-up admission replay-safe; the Harness handles the queue. Stop drops
reports already queued, rather than retrying them. A job finishing later can
still wake the model. Interrupted shell commands are reported, never rerun.

The model receives the complete bounded result, while Oppi displays a compact
result card instead of a synthetic user bubble containing raw output. This uses
generic input presentation metadata shared by live and history projections.
The classic extension above is unchanged. See
[Durable background jobs](../../dev/architecture-server/durable-extension-ui.md#background-jobs)
for restart, output, and Stop details.

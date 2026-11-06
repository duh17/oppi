# background-jobs

Reference Pi extension. Not a product feature. Copy it if you want long shell commands to leave the foreground and come back as a follow-up.

Bash waits 15 seconds. If the command is still running, it becomes a background job and a composer pill shows it. In the terminal the band stays collapsed: a spinner, the job, and the last output line. Ctrl+O, the same key as tool output, expands the tail and wraps long lines; click the band to toggle that too. In Oppi, tap a job row in the pill's drawer to see that job's live output tail, colors and progress redraws included. The tail refreshes with the widget (at most every 400 ms) and is display only; the model still gets output once, in the batched result. Finished results are batched at the next safe model boundary, or sent once when the session is idle. A stop does not wake the model just to acknowledge them. A trailing `&` backgrounds immediately. Polling a running job is blocked.

In an Oppi auto-stop session (subagents auto-stop by default), when the agent finishes its reply while jobs are still running, the session stays busy until a result arrives. The result continues the run without polling or model requests during the wait, so a supervising parent hears the final answer instead of "waiting on the build". Oppi keeps a session with running jobs loaded through the pending wake either way. Stop interrupts the wait; queued steering and follow-up messages typed by the user can also continue the run. Custom follow-ups from other extensions cannot end the wait because Pi does not report them to extensions, so the turn does not hold while another extension reports a pending wake on `oppi:pending-wake:v1`, such as `subagents` with a supervised child still due.

Other Oppi sessions do not hold the turn. The agent settles while jobs run, results start a new turn when they arrive, and other extensions' follow-ups start a turn right away. The first time a turn would end with a job running, the extension runs `oppi session get <id> --json` once and remembers `launch.autoStop` for the rest of the session. It never polls. If the lookup fails (plain Pi, no `oppi` CLI, or a session Oppi does not know), it holds, as before.

In an auto-stop session, a server or watcher that never exits keeps the session busy. Cancel the job or stop the session when you no longer need it. This extension does not provide a detached-job mode.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./server/plugins/background-jobs
```

Then ask for a command that should keep running, or call the `background_job` tool with `start`.

## Server-Durable implementation

`server.ts`, the plugin for durable sessions, uses conversation-owned background tasks and the reporter pattern
from pi-durable's `test/examples/23-subagent-background.ts`. A stable request ID
makes follow-up admission replay-safe; the Harness handles the queue. Stop drops
reports already queued, rather than retrying them. A job finishing later can
still wake the model. Interrupted shell commands are reported, never rerun.

The model receives the complete bounded result, while Oppi displays a compact
result card instead of a synthetic user bubble containing raw output. This uses
generic input presentation metadata shared by live and history projections.

The job pill in a durable session is a surface (`panel.ts`), not the classic
widget. It shows while a backgrounded job runs or its result waits for delivery,
and clears once every result is delivered. The pill counts the jobs ("1 job
running", "2 jobs · 1 running"); it never repeats a command. While a job runs,
the pill also shows a spinner, how long the oldest running job has run, and the
last line the newest running job printed, cut to 40 characters. When a listed
job failed or was interrupted, a red badge counts it ("2 failed").

In the drawer, each job is one row: a status glyph, a short title (the program
and its first plain arguments, without a leading `cd … &&`, options, pipes, or
redirects), and the job id with its age in whole minutes or how it ended
(`Exit 1`, `Stopped`, `Timed out`). The age is redrawn each minute. A running
job has a **Stop** button, which kills it as `background_job cancel` does.
Under the title, a running job shows its folder, the time left before its
timeout if it has one, and its live output: the last 12 lines, at most 480
characters, with escape codes removed and a progress line that redraws itself
with a carriage return shown at its latest state. When the output passes the
64,000 characters the result keeps, the row says "Output truncated".
**Details**, folded by default, holds the full command, with the full working
directory while the job runs or the end of its output once it has finished.

New output redraws the panel at most once every 2 seconds, and only when a
running row's lines would change. Several jobs printing at once share that
pace, and a command still in the foreground does not redraw the panel. The
live output is read from the output the job's runner already holds in memory.
It is never saved, and it does not reach the transcript or the model. A job's
output is still saved once, when the job ends, and the model reads it once, in
the result.

The panel is drawn from the saved job list, so it returns after a server
restart once a job's runner resumes, and within a second when a Session stops
and starts again while a job runs. The runner outlives the Session, so the live
output continues in the new panel. A client that cannot draw surfaces sees the
same jobs without buttons.

The classic extension above is unchanged. It can publish only Pi's widget, which
has no buttons, so it offers no Stop. See
[Durable background jobs](../../dev/architecture-server/durable-extension-ui.md#background-jobs)
for restart, output, and Stop details.

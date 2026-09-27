# background-jobs

Reference Pi extension. Not a product feature. Copy it if you want long shell commands to leave the foreground and come back as a follow-up.

Bash waits 15 seconds. If the command is still running, it becomes a background job and a composer pill shows it. Finished results are batched at the next safe model boundary, or sent once when the session is idle. A stop does not wake the model just to acknowledge them. A trailing `&` backgrounds immediately. Polling a running job is blocked.

When the agent finishes its reply while jobs are still running, the session stays busy until a result arrives. The result continues the run without polling or model requests during the wait. This prevents Oppi auto-stop from ending the session before the job finishes. Stop interrupts the wait; queued steering and follow-up messages can also continue the run.

A server or watcher that never exits keeps the session busy. Cancel the job or stop the session when you no longer need it. This extension does not provide a detached-job mode.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./pi-extensions/background-jobs
```

Then ask for a command that should keep running, or call the `background_job` tool with `start`.

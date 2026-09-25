# background-jobs

Reference Pi extension. Not a product feature. Copy it if you want long shell commands to leave the foreground and come back as a follow-up.

Bash waits 15 seconds. If the command is still running, it becomes a background job and a composer pill shows it. Finished results are batched at the next safe model boundary, or sent once when the session is idle. A stop does not wake the model just to acknowledge them. A trailing `&` backgrounds immediately. Polling a running job is blocked.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./pi-extensions/background-jobs
```

Then ask for a command that should keep running, or call the `background_job` tool with `start`.

# background-jobs

Reference Pi extension. Not a product feature. Copy it if you want long shell commands to leave the foreground and come back as a follow-up.

Bash waits 15 seconds. If the command is still running, it becomes a background job, a composer pill shows it, and the output is injected when it finishes. A trailing `&` backgrounds immediately. Polling a running job is blocked.

## Try it

Link the package where Pi discovers extensions, or run:

```bash
pi -e ./pi-extensions/background-jobs
```

Then ask for a command that should keep running, or call the `background_job` tool with `start`.

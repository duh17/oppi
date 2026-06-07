# oppi-goal

`oppi-goal` is a plain Pi extension that keeps an active goal moving until it is complete, blocked, paused, or cleared.

It uses only standard Pi extension APIs:

- `/goal` command
- `goal_update` and `goal_status` tools
- session custom entries for persistence
- `ctx.ui.setWidget("goal", component)` for a progress widget with line fallback
- hidden follow-up messages for continuation

## Use

```text
/goal simplify the queue projection and keep working until it is complete
/goal status
/goal pause
/goal resume
/goal clear
/goal complete
```

For multi-step goals, the agent calls `goal_update` with `tasks` to create a durable checklist, then uses `taskUpdates` to mark one-based widget rows as `pending`, `in_progress`, or `completed`.

Use top-level `status` for the whole goal: `active`, `paused`, `complete`, `blocked`, or `cleared`. Use `tasks[].status` or `taskUpdates[].status` for checklist rows. The extension accepts top-level `status: "in_progress"` as `active` because agents commonly make that mistake on the first update.

The widget is rendered as normal Pi widget lines, with an Oppi native `activityList` and `progress` surface attached when available. Oppi sessions and mirrored terminal sessions display it through the existing extension UI forwarding path.

Goal continuation messages are hidden trigger messages. The extension keeps only the latest goal context in model input, restores state from the active Pi branch, and stops continuing when the goal is completed, blocked, paused, cleared, over budget, or waiting behind queued user input.

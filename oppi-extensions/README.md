# oppi-extensions

Local pi package for Oppi extensions, prompts, skills, and themes.

Oppi server sessions load these wrappers directly from this repo when the workspace enables them, so Oppi itself does not require a separate `pi install` step.

If you want the same extensions in plain pi TUI sessions, install the package by local path so it loads everywhere while still editing in place:

```bash
pi install ~/workspace/oppi/oppi-extensions
```

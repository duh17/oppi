# Provider quotas and pace

Oppi reports how much model-provider quota remains in each usage window, and whether that remainder is ahead of the time left until reset. The provider supplies the remaining percent and reset time. The server derives pace from that snapshot, and the app shows the server's result without calculating anything itself.

## Where to look

- App: **Server Settings → Model Providers** shows every window. Compact UI, including the model picker, shows the shortest window.
- CLI: `oppi quota` and `oppi models`.
- API: `GET /server/provider-quotas`.

Windows are listed shortest period first. A globally enabled Pi extension can add providers ([Provider quota extension API](extensions.md#provider-quota-extension-api)).

## Remaining vs pace

| Signal | Meaning | Display |
| --- | --- | --- |
| Remaining | How much of the window is left | `% left` and the bar: green above 50%, orange above 20% through 50%, red at 20% or below |
| Pace | Remaining quota vs remaining time | `Plenty · 1.30× supply` |

| Pace label | Supply ratio |
| --- | --- |
| Plenty | greater than 1.20 |
| On pace | 0.80 through 1.20 |
| Conserve | less than 0.80 |
| Not enough data to calculate | no usable snapshot |

`1.00× supply` means the remaining quota fraction equals the remaining time fraction. Above it, more quota remains than time; below it, quota runs out faster than the window.

## Formula

Let \(r\) be remaining quota clamped to \(0\ldots1\), \(t\) the seconds until reset, and \(W\) the window length in seconds.

\[
\mathrm{supply} = \frac{r}{t / W}
\]

The server also stores a target burn rate that the UI does not show, the spend rate that reaches 0% exactly at reset:

\[
\mathrm{target\ burn\ \%/h} = \frac{r \times 100}{t / 3600}
\]

`resetAt` is Unix time in seconds and `fetchedAt` is Unix time in milliseconds, so \(t = \mathrm{resetAt} - \mathrm{fetchedAt}/1000\).

Example: a 5-hour window (\(W = 18{,}000\)) with 2.5 hours left. At 50% left, \(\mathrm{supply} = 0.50 / (9{,}000 / 18{,}000) = 1.00\), so **On pace**. With the same time left, 65% left is \(1.30\times\) (Plenty), 40% is \(0.80\times\) (On pace), and 30% is \(0.60\times\) (Conserve).

**Not enough data to calculate** appears when the reset time is missing or already past, the window length is missing or not above 0, or remaining percent is not a finite number. The app also shows it when the server omits `pacing`, which happens with a server built before that field; rebuild and restart the server.

Pace uses only the current snapshot. It does not use spend history, so recent burn, pace ratio, and projected exhaustion stay empty.

## OpenAI: Sign in with ChatGPT vs legacy Codex

The two OpenAI providers keep separate credentials, and Oppi never sends one provider's token to the other's endpoint.

| Provider id | Auth | Quota (default) |
| --- | --- | --- |
| `openai-codex` (legacy) | Codex OAuth | Windows and plan from the Codex usage endpoint |
| `openai` | Sign in with ChatGPT (OAuth) | Unknown: connected, no windows, and a note pointing to [ChatGPT usage settings](https://chatgpt.com/settings/usage) |
| `openai` | OpenAI API key | Not authenticated for quota: no windows and no note. API keys bill per token and have no subscription window |

No supported quota API exists for Sign in with ChatGPT, and OpenAI's docs say to send that token only to `https://api.openai.com/v1`. By default Oppi therefore makes no request for the `openai` provider and never reuses the Codex endpoint or token. The CLI prints the note in red and Server Settings in gray; both mean "unknown", not "failed".

### Opt in: plan-wide usage via the legacy Codex connection

If your legacy Codex sign-in belongs to the **same ChatGPT account and workspace** as the official sign-in, you can show its plan-wide usage on the `openai` row:

```bash
oppi config set providerQuotas.openaiUseCodexPlan true
oppi server restart
```

The default is `false`. The running server reads its config once at startup, so it keeps the old setting until you restart.

- **You confirm the pairing.** Oppi does not verify that the two sign-ins match. If either changes, confirm again, and turn the setting off if they no longer match.
- **One upstream request, legacy token only.** Oppi reuses the `openai-codex` row it already fetched, and the official token never goes to the Codex endpoint.
- **Plan-wide, not app-specific.** The numbers are the plan's Codex usage windows, not Pi's app-specific cap, which stays unknown. The row is labelled `OpenAI (ChatGPT plan via legacy Codex)`, with window titles such as `Weekly plan (via legacy Codex)` and short labels such as `Plan 7d`.
- **Errors stay visible.** If the Codex connection is missing, signed out, fails, or returns no windows, the `openai` row stays connected with no windows and shows the reason. Nothing stale appears.
- **Only official OAuth.** An OpenAI API key or a missing official credential never gets subscription quota, and the `openai-codex` row is unchanged.

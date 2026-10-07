# Provider quotas and pace

Oppi reports how much model-provider quota remains in each usage window, and whether that remainder is ahead of the time left until reset.

Remaining percent and reset time come from the provider. The Oppi server derives pace from that snapshot. The Apple client renders the server payload and does not calculate pace itself.

## Where to look

- Apple: **Server Settings** → **Model Providers**
- CLI: `oppi quota` and `oppi models`
- API: `GET /server/provider-quotas`

Windows are shortest period first. Compact UI, including the model picker, shows the shortest window. Server Settings → Model Providers shows every window.

## Remaining vs pace

These are separate signals.

| Signal | Meaning | Display |
| --- | --- | --- |
| Remaining | How much of the window is left | `% left` and the bar |
| Pace | Remaining quota vs remaining time | `Plenty · 1.30× supply` |

Remaining color uses remaining percent only:

- green: above 50%
- orange: above 20% through 50%
- red: 20% or below

Pace labels use the supply ratio:

| Label | Supply ratio |
| --- | --- |
| Plenty | greater than 1.20 |
| On pace | 0.80 through 1.20 |
| Conserve | less than 0.80 |
| Not enough data to calculate | no usable snapshot |

`1.00× supply` means the remaining quota fraction matches the remaining time fraction. Above `1.00×`, more quota remains than time. Below `1.00×`, quota is running out faster than the window.

## Formula

Let \(r\) be remaining quota, clamped to \(0\ldots1\). Let \(t\) be seconds until reset. Let \(W\) be the full window length in seconds.

\[
\mathrm{supply} = \frac{r}{t / W}
\]

The server also stores a target burn rate, which the UI does not show:

\[
\mathrm{target\ burn\ \%/h} = \frac{r \times 100}{t / 3600}
\]

That is the spend rate that reaches 0% exactly at reset.

`resetAt` is Unix time in seconds. `fetchedAt` is Unix time in milliseconds. Time remaining is \(t = \mathrm{resetAt} - \mathrm{fetchedAt}/1000\).

## Example

A 5-hour window (\(W = 18{,}000\)) with 50% left and 2.5 hours until reset:

\[
\mathrm{supply} = \frac{0.50}{9{,}000 / 18{,}000} = 1.00 \rightarrow \text{On pace}
\]

Same window, still half the time left:

- 65% left → \(1.30\times\) → Plenty
- 40% left → \(0.80\times\) → On pace
- 30% left → \(0.60\times\) → Conserve

## Not enough data to calculate

The server returns unknown pace when any of these is true:

- reset time is missing
- reset time is already past
- window length is missing or not greater than 0
- remaining percent is not a finite number

The Apple client also shows **Not enough data to calculate** when the server omits `pacing`. That happens with a server built before this field. Rebuild and restart the server.

## Snapshot only

Pace uses the current remaining percent and reset time. It does not use observed spend history. Recent burn, pace ratio, and projected exhaustion stay empty.

## OpenAI: Sign in with ChatGPT vs legacy Codex

The two OpenAI providers keep separate credentials, and Oppi never sends one provider's token to the other's endpoint.

| Provider id | Auth | Quota (default) |
| --- | --- | --- |
| `openai-codex` (legacy) | Codex OAuth | Windows and plan from the Codex usage endpoint |
| `openai` | Sign in with ChatGPT (OAuth) | Unknown. Connected, no windows, and a note pointing to [ChatGPT usage settings](https://chatgpt.com/settings/usage) |
| `openai` | OpenAI API key | Not authenticated for quota: no windows and no note. API keys bill per token and have no subscription window |

No supported quota API was identified for Sign in with ChatGPT, and OpenAI's docs say to send that token only to `https://api.openai.com/v1`, not to ChatGPT `backend-api` endpoints. By default Oppi therefore makes no request for the `openai` provider and never reuses the Codex endpoint or token. The CLI prints the note in red and Server Settings → Model Providers in gray; both mean "unknown", not "failed".

### Opt in: plan-wide usage via the legacy Codex connection

If you keep the legacy Codex sign-in and it belongs to the **same ChatGPT account and workspace** as the official sign-in, you can show its plan-wide usage on the `openai` row:

```bash
oppi config set providerQuotas.openaiUseCodexPlan true
```

The default is `false`. The running server reads its config once at startup, and `oppi config set` writes the file from a separate process. Restart the server (`oppi server restart`) for the change to take effect; until then the running server keeps its previous setting.

- **You confirm the pairing.** Oppi does not infer or verify that the two sign-ins match. If either sign-in changes, confirm again, and turn the setting off if they no longer match.
- **One upstream request, legacy token only.** Oppi reuses the `openai-codex` row it already fetched. The official token is never sent to the Codex endpoint.
- **Plan-wide, not app-specific.** The numbers are the plan's Codex usage windows. They are not Pi's app-specific cap, which stays unknown. The row is labelled with the existing metadata: display name `OpenAI (ChatGPT plan via legacy Codex)`, window titles such as `Weekly plan (via legacy Codex)`, and short labels such as `Plan 7d` for compact badges.
- **Errors stay visible.** If the Codex connection is missing, signed out, fails, or returns no windows, the `openai` row stays connected with no windows and shows that reason. Nothing stale or empty-success is shown.
- **Only official OAuth.** An OpenAI API key or a missing official credential never receives subscription quota. The `openai-codex` row is unchanged.

Where the setting lives in code: `providerQuotas.openaiUseCodexPlan` (`server/src/types/config.ts`), merged in `withLegacyCodexPlanQuota` (`adapters/openai.ts`).

## Code

- Derivation: `server/src/provider-quota/shared.ts` (`deriveProviderQuotaPacing`)
- Built-in provider adapters: `server/src/provider-quota/adapters/registry.ts`
- Extension-provided quota: [Provider quota extension API](extensions.md#provider-quota-extension-api). Extensions own provider-specific auth, fetch, and parsing; Oppi validates and renders the shared quota shape.
- Apple presentation: `clients/apple/Oppi/Features/Servers/ServerDetailView.swift`

Do not branch Apple UI on provider names. Keep provider-specific parsing in the adapter.

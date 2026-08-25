# Provider quotas and pace

Oppi reports how much model-provider quota remains in each usage window, and whether that remainder is ahead of the time left until reset.

Remaining percent and reset time come from the provider. The Oppi server derives pace from that snapshot. The Apple client renders the server payload and does not calculate pace itself.

## Where to look

- Apple: **Server** detail → **Model Providers**
- CLI: `oppi quota` and `oppi models`
- API: `GET /server/provider-quotas`

Windows are shortest period first. Compact UI, including the model picker, shows the shortest window. Server detail shows every window.

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

## Code

- Derivation: `server/src/provider-quota/shared.ts` (`deriveProviderQuotaPacing`)
- Add a provider: `server/src/provider-quota/adapters/registry.ts`
- Apple presentation: `clients/apple/Oppi/Features/Servers/ServerDetailView.swift`

Do not branch Apple UI on provider names. Keep provider-specific parsing in the adapter.

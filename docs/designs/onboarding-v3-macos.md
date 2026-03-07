# Oppi onboarding v3 — native macOS companion app

**Status:** Draft  
**TODO:** TODO-06f9343f  
**Related:** `docs/designs/onboarding-v2.md` (transport / daemon reference; partially stale for primary UX)

## Goal

Make the primary Mac onboarding path zero-CLI:

1. Download a native macOS app
2. Launch it
3. Let it initialize and run the local Oppi server
4. Show a pairing QR in the Mac app
5. Scan it from iPhone
6. Create a workspace and start using Oppi

## Non-goals for v1

- Linux / headless onboarding parity
- Cloudflare / public internet exposure
- Mac App Store distribution
- Full code sharing with the existing iOS app
- Background persistence when the Mac app is fully quit

---

## 1. Verified repo state

### 1.1 What already exists

#### Server runtime is already usable as the engine

The server CLI already provides the core runtime and admin surface we need:

- `oppi serve`
- `oppi pair`
- `oppi doctor`
- `oppi config ...`

References:

- `server/src/cli.ts`
- `ARCHITECTURE.md`
- `server/README.md`

#### Pairing protocol is real and good enough

The pairing flow already exists end to end:

- CLI issues one-time `pairingToken`s via `Storage.issuePairingToken()`
- iPhone exchanges the token with `POST /pair`
- invite payload includes:
  - host
  - port
  - scheme
  - pairing token
  - TLS leaf fingerprint for self-signed mode
  - stable server identity fingerprint

References:

- `server/src/cli.ts` (`showPairingQR`)
- `server/src/storage/auth-store.ts`
- `server/src/routes/identity.ts`
- `server/src/types.ts`
- `ios/Oppi/Core/Models/User.swift`
- `ios/Oppi/Features/Onboarding/OnboardingView.swift`

#### TLS building blocks exist

Implemented today:

- self-signed TLS material generation
- Tailscale TLS material generation
- cert fingerprint reading for pinning

References:

- `server/src/tls.ts`

#### iPhone-side onboarding already works

The iOS app already supports:

- QR scan
- manual server entry
- pairing bootstrap
- trust confirmation when invite fingerprint is present

References:

- `ios/Oppi/Features/Onboarding/OnboardingView.swift`
- `ios/Oppi/Features/Onboarding/QRScannerView.swift`

#### Post-pair workspace creation is in much better shape than before

The iOS app already calls `GET /host/directories` and presents a project-first workspace picker.

References:

- `server/src/host.ts`
- `server/src/routes/skills.ts`
- `ios/Oppi/Core/Networking/APIClient.swift`
- `ios/Oppi/Core/Models/HostDirectory.swift`
- `ios/Oppi/Features/Workspaces/WorkspaceCreateView.swift`

#### Server health / metadata endpoints already exist

These are enough for a native Mac supervisor UI to determine readiness and show status:

- `GET /health`
- `GET /server/info`

References:

- `server/src/server.ts`
- `server/src/routes/identity.ts`
- `ios/Oppi/Core/Models/ServerInfo.swift`

### 1.2 What does not exist yet

#### No native macOS app target

The Xcode project has only iOS targets today. There is no macOS shell, no menu bar app, and no companion UI.

References:

- `ios/project.yml`

#### No focused design doc for the macOS path

`docs/designs/onboarding-v2.md` is useful background, but it still frames npm / CLI onboarding as the main path.

#### Docs are still CLI-first

The top-level install docs still say:

- clone repo
- `npm install`
- `npx oppi serve`

References:

- `README.md`
- `server/README.md`

#### No machine-readable pairing invite surface

Today pairing invite generation is trapped inside CLI presentation code:

- `showPairingQR()` generates the invite payload
- then prints terminal QR + deep link
- there is no `--json` mode
- there is no HTTP route that returns a fresh invite for native UI

This is the single biggest missing artifact for a macOS app QR surface.

Reference:

- `server/src/cli.ts`

#### No machine-readable diagnostics surface

`oppi doctor` is useful, but it is terminal-formatted text only. A native diagnostics view can show raw text initially, but richer UI will want structured output eventually.

Reference:

- `server/src/cli.ts`

#### No bundle pipeline for a zero-CLI Mac app

There is no script or packaging flow that stages:

- a Node runtime
- `server/dist`
- runtime dependencies (`node_modules`)
- bundled skills/themes/extensions
- package metadata the server reads at runtime

for inclusion inside a macOS app bundle.

### 1.3 Important implementation constraints discovered in code

#### Constraint A — default config is still TLS-disabled

Fresh `Storage` config defaults to:

- `host: 0.0.0.0`
- `tls.mode: "disabled"`

Only `oppi init` switches first-run config to `self-signed`.

That means a native macOS onboarding app cannot just “start the server” and assume HTTPS exists. It must either:

- explicitly initialize config like `oppi init --yes`, or
- directly write equivalent config before starting.

References:

- `server/src/storage/config-store.ts`
- `server/src/cli.ts` (`cmdInit`)

#### Constraint B — current runtime update flow is npm-shaped, not app-bundle-shaped

The server currently exposes runtime update status and an npm-based update path. That model assumes:

- `npm` exists on the host
- updating packages in place is allowed
- a supervisor restarts the process after update

That is a poor match for a signed app bundle.

References:

- `server/src/runtime-update.ts`
- `server/src/routes/identity.ts`
- `server/src/server.ts`

#### Constraint C — existing iOS app code is not a drop-in macOS app

The current iOS app tree is heavily iOS-specific:

- UIKit-heavy timeline rendering
- VisionKit onboarding scanner
- ActivityKit / WidgetKit pieces
- iOS app delegate / UIApplication dependencies

There is reusable model/networking code, but there is no “flip platform to macOS” shortcut.

References:

- `ios/project.yml`
- `ios/Oppi/Features/Onboarding/OnboardingView.swift`
- broad UIKit/VisionKit usage across `ios/Oppi/`

---

## 2. Biggest product / architecture decisions

### Decision 1 — v1 should be app-supervised, not launchd-required

**Recommendation:** the native macOS app should own the server process directly for v1.

Why:

- fastest path to a working native shell
- avoids immediate launchd / helper / login-item complexity
- keeps all onboarding state inside one visible app
- already matches the “managed server” intent
- existing `/health` + `/server/info` are enough for readiness

Implication:

- if the user fully quits the Mac app, the server stops
- that is acceptable for v1
- launch-at-login / background persistence becomes a later slice

`onboarding-v2.md` launchd details remain useful reference material, but they should not block v1.

### Decision 2 — zero-CLI release requires a bundled runtime

A real zero-CLI Mac onboarding story cannot depend on the user having:

- Node installed
- a git checkout
- `npm install` having been run

So the release app must bundle the server runtime.

**Recommended split:**

- **dev dogfood mode:** Mac app may point at repo-local `server/dist/cli.js`
- **credible user-facing v1:** Mac app bundles Node + staged server runtime resources

### Decision 3 — do not over-optimize Swift code sharing up front

The fastest credible v1 is a new standalone macOS target with its own small source tree.

Do **not** start by trying to share the full iOS app architecture.

What can be shared later if helpful:

- invite payload model types
- simple API client pieces
- common formatting / small utilities

What should stay separate initially:

- onboarding UI
- process supervision
- logs / diagnostics UI
- QR rendering

### Decision 4 — pairing invite generation needs a first-class machine-readable API

The macOS app should not scrape CLI stdout.

**Recommendation:** extract invite generation into a reusable server-side module and expose one of:

1. `oppi pair --json` (recommended first)
2. authenticated local HTTP route returning a fresh invite
3. both

The app can render QR natively from the returned invite payload or deep link.

### Decision 5 — bundled-app update story must be separate from npm runtime updates

For companion-managed servers, the update story should be:

- update the Mac app bundle
- restart bundled server

not:

- `npm install` into app resources

So v1 should either:

- disable the current npm runtime-update surface in bundle mode, or
- clearly mark it unsupported for companion-managed installs

---

## 3. Fastest credible v1 plan

### Phase A — add the minimum server surfaces the Mac app needs

### A1. Extract invite generation from CLI presentation code

Create a reusable server-side invite module that returns structured data:

- invite payload JSON
- deep link URL
- transport metadata
- TLS fingerprint if present
- display name / host / port

Possible file:

- `server/src/invite.ts`

Then make `server/src/cli.ts` consume that module instead of owning the logic.

### A2. Add `oppi pair --json`

This is the smallest useful bridge for a native app.

Suggested output shape:

```json
{
  "host": "mac-studio.local",
  "port": 7749,
  "scheme": "https",
  "name": "mac-studio",
  "pairingToken": "pt_...",
  "fingerprint": "sha256:...",
  "tlsCertFingerprint": "sha256:...",
  "inviteJson": "{...}",
  "inviteURL": "oppi://connect?..."
}
```

### A3. Optionally add `oppi doctor --json`

Not strictly required for the first shell app, but very useful for a native diagnostics surface.

If deferred, v1 can show raw `oppi doctor` text in a scroll view.

### A4. Add a server bundle staging script

Create a script that stages the runtime payload for the Mac app bundle.

Likely inputs:

- `server/dist/`
- `server/node_modules/`
- `server/package.json`
- `server/skills/`
- `server/themes/`
- `server/extensions/`

Likely output:

- a single directory copied into macOS app resources during build

This is the artifact boundary that turns “repo code” into “bundled runtime”.

### Phase B — build the native macOS shell

### B1. Add a macOS target to the existing XcodeGen project

Recommended approach:

- keep using `ios/project.yml`
- add a new macOS application target
- create a new source directory, e.g. `ios/OppiMac/`

Why this is the fastest path:

- existing build tooling already uses XcodeGen
- same repo, same team settings, same release tooling neighborhood
- no need to invent a second Swift project system

### B2. App responsibilities for v1

The macOS app only needs four core jobs:

1. initialize config on first launch
2. start / stop / restart the local server process
3. generate and display pairing QR
4. show logs / diagnostics

### B3. Process supervision model

Use `Process` to launch the bundled server runtime.

Recommended lifecycle:

- first launch:
  - ensure data dir exists
  - run noninteractive init equivalent with `self-signed` TLS
- normal launch:
  - start child process
  - stream stdout/stderr to in-app log buffer
  - poll `/health`
  - when healthy, fetch `/server/info`

### B4. Native UI surface for v1

Single-window SwiftUI app is enough.

Suggested sections:

- **Status**
  - running / stopped / starting / unhealthy
  - URL
  - TLS mode
  - app + server version
- **Controls**
  - start
  - stop
  - restart
  - regenerate pairing invite
- **Pair iPhone**
  - QR code
  - copy invite link
  - copy server URL
- **Diagnostics**
  - recent stdout/stderr logs
  - doctor output
  - open data directory

No menu bar extra is required for v1.

### B5. Readiness contract

Use existing endpoints first:

- `/health` for readiness
- `/server/info` for metadata/status

Do not invent a new status protocol unless the current endpoints prove insufficient.

### Phase C — make it distributable

### C1. Dogfood milestone

Local Xcode build is enough to prove the UX.

### C2. First external milestone

A notarized DMG with bundled runtime is the first credible external onboarding story.

Do not block shell implementation on notarization, but also do not confuse “local build works” with “zero-CLI product path is done”.

---

## 4. Recommended v1 scope cuts

These cuts keep the project honest and shippable.

### Keep

- native Mac shell app
- self-signed local HTTPS by default
- QR-first pairing
- logs / diagnostics
- workspace creation remains on iPhone

### Defer

- launchd-managed persistence
- launch-at-login
- Tailscale polish beyond current working path
- npm publish cleanup as a primary story
- Docker / Linux parity work
- public internet / Cloudflare
- full app self-update pipeline

---

## 5. Missing artifacts to create next

1. **Design doc** — this file
2. **Machine-readable invite generation**
3. **Mac app target + shell**
4. **Bundle staging script for server runtime**
5. **Updated README / onboarding docs** describing:
   - macOS app = primary path
   - CLI = fallback / dev / Linux path
   - Docker = advanced path

---

## 6. Recommended immediate next steps

1. **Server prep:** extract invite generation and add `oppi pair --json`
2. **Packaging prep:** add a bundle staging script for the server runtime
3. **App shell:** add a macOS target and implement start/stop/status/logs
4. **Pairing UI:** render QR natively from the JSON invite payload
5. **Docs:** update root README after the shell exists, not before

---

## 7. Summary recommendation

The fastest credible v1 is:

- a native macOS companion app
- supervising the existing Node server as a child process
- initializing self-signed TLS on first launch
- showing a native QR pairing screen
- requiring the app to remain running for v1
- bundling the runtime for real zero-CLI release builds

The main blockers are not transport or iPhone pairing anymore. They are:

1. no macOS app target
2. no machine-readable invite generation surface
3. no bundled runtime packaging path

Everything else is follow-through.

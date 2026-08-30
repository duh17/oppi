# Mac parity finish line — 2026-08-29

## Result

For production source through `b4057be5`, the Mac parity ledger has no open finish-line row.

Of the 54 rows that were `gap=mac-behind` or `gap=planned` in the 2026-08-28 inventory:

| Disposition | Rows |
|---|---:|
| `mac=full,gap=none` | 37 |
| `gap=wont-fix` | 17 |
| `gap=mac-behind` | 0 |
| `gap=planned` | 0 |

The CSV still has 82 data rows. Five pre-existing device-only rows—haptics, the Live Activities experiment control, share extension, Control widget, and Live Activities—are also explicit `wont-fix` rows. They are outside the 54-row former-target count.

This is a current-source closure, not a claim of visual approval, distribution readiness, or shipping. No running-app visual gate was performed for this report.

## Production baseline

Mac now has a functional native baseline for the finish-line areas. The implementation shares UIKit-free models, parsers, projections, and policies through `OppiCore`, then paints Mac behavior in SwiftUI/AppKit. It does not copy the iOS `ChatView`, `ChatActionHandler`, UIKit timeline, or `ToolTimelineRowContent`.

The production callers checked for full rows are:

| Area | Current Mac behavior | Production evidence |
|---|---|---|
| Shell and sessions | Live Home and destination sidebar, worktree-aware rows and workspace switcher, session deeplinks that fetch uncached sessions and retry after cold server readiness, local Pi import, and ordinary guided control-session chats | [[clients/apple/OppiMac/Views/MainWindowView.swift|Main window routing]], [[clients/apple/OppiMac/App/OppiMacApp.swift|Mac scene and deeplinks]], [[clients/apple/OppiMac/Views/MacWorkspaceShellViews.swift|Workspace session surface]] |
| Composer | Attachment select/drop/paste with thumbnails and cleanup, slash completion, complete ask cards, and generic extension surfaces | [[clients/apple/OppiMac/Views/MacSessionComposerBar.swift|Mac composer]], [[clients/apple/OppiMac/Session/MacPendingAttachment.swift|Attachment staging]], [[clients/apple/OppiMac/Views/MacExtensionSurfacePanel.swift|Extension UI painter]] |
| Timeline and Markdown | Shared CommonMark parse with tables, HTML/SVG, Mermaid, LaTeX, images, video, thinking folds, context chrome, review comments, and wiki/file routing | [[clients/apple/OppiMac/Views/MacMarkdownBlockViews.swift|Markdown painter]], [[clients/apple/OppiMac/Views/MacSessionTimelineViews.swift|Timeline painter]], [[clients/apple/OppiMac/Views/MacSessionContextInspectorView.swift|Context inspector]] |
| Tool and file documents | Session-owned expansion plus a wide side-column viewer for code, structured diff, ANSI terminal, images, audio/video, PDF, HTML, and SVG; system fullscreen is the escalation | [[clients/apple/OppiMac/Views/MacSessionShellViews.swift|Session document-column caller]], [[clients/apple/OppiMac/Views/MacToolDocumentColumn.swift|Document column]], [[clients/apple/OppiMac/Views/MacToolDocumentMedia.swift|Media painter]], [[clients/apple/OppiMac/Views/MacPDFPreview.swift|PDF painter]] |
| Keyboard | Shared focus-aware Mac-default/Vim catalog, live Mac mode picker, and iOS/iPad hardware-keyboard adapter; composer letters and Cmd-Return remain composer-owned | [[clients/apple/OppiCore/Models/KeybindingCatalog.swift|Shared keybinding catalog]], [[clients/apple/OppiMac/Stores/MacSessionTraceStore.swift|Mac action caller]], [[clients/apple/OppiMac/Views/SettingsView.swift|Live Mac picker]], [[clients/apple/Oppi/Features/Chat/Session/HardwareKeybindingResponder.swift|iOS/iPad responder]] |
| Workspaces, files, and Git | Selected-worktree session, import, file, media, Git status, diff, and viewer requests; session changed-file preview and review | [[clients/apple/OppiMac/Views/MacWorkspaceShellViews.swift|Workspace callers]], [[clients/apple/OppiMac/Views/MacWorkspaceFileBrowserView.swift|File browser]], [[clients/apple/OppiMac/Views/MacWorkspaceGitStatusView.swift|Git status]], [[clients/apple/OppiMac/Stores/MacWorkspaceGitReviewStore.swift|Git review store]] |
| Catalogs | Live Agent, Schedule, Skill, and Extension lists/details; common native editing and status controls; guided Agent, Schedule, and Workspace configuration sessions | [[clients/apple/OppiMac/Views/MacCatalogViews.swift|Catalog surfaces]], [[clients/apple/OppiMac/Views/MacCatalogStore.swift|Catalog and control-session state]] |
| Settings and system | Theme import, live built-in/emoji avatar and spinner controls, real typography, screen-awake reconciliation, Mac-owned cache clearing, live Stats/context, and local ask notifications with session routing | [[clients/apple/OppiMac/Views/SettingsView.swift|Settings callers]], [[clients/apple/OppiMac/Formatting/MacSyntaxHighlighter.swift|Mac typography]], [[clients/apple/OppiMac/Services/MacScreenAwakeController.swift|Screen-awake controller]], [[clients/apple/OppiMac/App/MacAttentionNotificationService.swift|Attention notifications]] |

The side column remains separate from the narrow changed-files inspector. No detached viewer is the first hop. The owner token remains on the local Unix socket.

## Finish-line correctness evidence

The source before `c2cd2ea3` already closed the stale shell, import, control-session, composer, slash, extension-UI, timeline, viewer, media, shared-keybinding, Files/Git, catalog-baseline, settings, Stats, and attention rows.

The audited production source adds these correctness slices:

| Commit | Current guarantee | Same-model review outcome |
|---|---|---|
| `3f82f726` | A Markdown document derives `sourceDirectory` from `filePath`; nested relative links and images reach parse and load callers with the correct directory. | **Accept.** No correctness finding; a source-shape test remains weaker than a mounted request interception test. |
| `d62b7074` + `288bd97a` | One atomic control-launch request and idempotency key survive retry. Success clears only the unchanged source draft; revised work stays local and receives a new key on its later send. In-flight cancel/reopen/duplicate sends cannot overwrite newer state. | `d62b7074` was **rejected** for revised-draft loss and an in-flight race. `288bd97a` was **accepted** with both findings closed. |
| `2f05a2e4` + `75870ec3` | Successful recent-session snapshots authoritatively replace the running-session awake set. Request generations make overlapping snapshot success/failure latest-wins; current failure preserves existing awake reasons. | `2f05a2e4` was **accept-with-fixes** for missing latest-wins and failure coverage. `75870ec3` was **accepted** with both findings closed. |
| `345d9f56` + `338b8f1a` | Mac ships and registers the bundled code fonts. Timeline, viewer, inspector, diff, terminal, and extension painters consume the selected family/scale and repaint without subtree identity resets. | `345d9f56` was **rejected** for unavailable bundled fonts, state-destroying invalidation, and missed painters. `338b8f1a` was **accepted** with all three findings closed. |
| `e6c2a2e0` + `4009b02e` + `25a9a4fd` | Mac Settings exposes a persisted Mac-default/Vim picker, and each key event reads the live mode without recreating session state. Tests restore every standard-default mutation and include Keybindings in the settings-control inventory. | Production behavior in `e6c2a2e0` was **accepted with one test-isolation fix**. The test-only `4009b02e` recovery was **accepted** after 14 unique tests passed and the external preference remained unchanged. The test-only `25a9a4fd` correction was **accepted** with no production change. |
| `40bbc65f` + `b4057be5` | Known session deeplinks open directly. Uncached sessions are fetched over the authenticated owner socket; links parked during cold startup retry after server readiness, and unresolved links fall back to Workspaces. | `40bbc65f` was **accept-with-fixes** because cold-start links could remain parked and the public deeplink contract was stale. The `b4057be5` recovery was **accepted** with both findings closed; the combined focused rereview with `25a9a4fd` reported 42 unique tests passed. |

The same-model reviews found no remaining production correctness blocker in these slices. They did not provide interactive visual approval.

## Explicit non-goals

These are deliberate finish-line boundaries, not missing baseline behavior:

- **Unread state:** Mac may paint a shared completion date, but it does not own an unread producer or a separate unread store.
- **Platform painters:** iOS keeps `ChatView`, `ChatActionHandler`, its UIKit timeline, and `ToolTimelineRowContent`. Mac keeps its SwiftUI/AppKit timeline and document painters.
- **Device surfaces:** widgets, Live Activities and their experiment control, share extension, and haptics stay on iOS/iPadOS targets. Compact turns stay an iPhone presentation. App-level biometric lock stays on iOS/iPadOS; Mac relies on host account security and TCC.
- **Host role:** Mac stays the local Oppi host and owner-socket client. Saved remote URLs do not make it a first-class paired remote client.
- **Viewer shape:** the wide side column remains the default. System fullscreen remains the deep-reading escalation. A `WindowGroup`-first or detached viewer is not a finish-line goal.
- **Product education and intake:** Mac keeps host onboarding, normal workspace session creation, and guided control-session entry points. iOS What's New, feature-education, Quick Session, Shortcut intake, and share intake do not move to Mac.
- **Outline depth:** Mac keeps server-backed timeline search/filter/jump. iOS Tree mode, branch navigation, and fork actions do not move to Mac.
- **Avatar depth:** Mac keeps built-in and emoji avatars plus spinner controls. It does not offer or decode Genmoji.

## Disposition of remaining iOS-depth differences

These rows retain useful Mac-native behavior and are explicit `wont-fix` rather than inflated to full:

| Difference | Mac baseline that remains | Finish-line disposition |
|---|---|---|
| Genmoji avatars | Live built-in and emoji avatar choices plus spinner controls | No Genmoji offering or decoding on Mac. |
| On-device/Off auto-title controls | Server-derived session titles and a visible Server source | No Mac on-device title engine or Off control. |
| On-device dictation engine picker | Server dictation over the owner Unix socket | No on-device engine or engine picker. |
| Configurable voice-reply mode | Server reply details, live WAV autoplay, and tap-to-play completed media | No native reply-mode selector. |
| Duplicate Mac menu command routing | Focus-local timeline/viewer handlers use the shared catalog | No second command-menu route and no global event monitor. |
| Full iOS workspace configuration form | Native common host create/edit/delete plus **Ask Oppi** and **Edit with Oppi** | No duplicate full sandbox/resource form. Guided configuration handles deep changes. |
| Full advanced native Agent fields | Native list/detail/create/edit/archive for common fields plus **Edit with Oppi** | No duplicate native controls for every model, tool, resource, and launch constraint field. |
| Full advanced Schedule fields | Native list/detail/create/edit/status controls plus **Edit with Oppi** | No duplicate native controls for every trigger/action form. |
| Skill auxiliary file-tree editor | Native list/detail, enable state, and `SKILL.md` display | No auxiliary file-tree editor. |
| Outline Tree/fork | Timeline outline search/filter/jump | No Tree/fork mode or fork action. |

Guided **Edit with Oppi** and **Ask Oppi** preserve deep configuration through ordinary inspectable control-session chats where those entry points apply. The native baseline remains available for common work.

## Validation boundary

This report and the CSV are documentation-only. Validation for the documentation commit is structural rather than a code-test rerun:

- parsed the CSV with Python's `csv` module;
- asserted 82 data rows;
- asserted zero `mac-behind` and zero `planned` gaps;
- asserted the declared status, gap, and sharing vocabularies;
- asserted the former 54 target rows resolve to exactly 37 full and 17 `wont-fix`;
- ran `git diff --check`.

No product code changed. No push was performed. `/Applications/Oppi.app` was not killed.

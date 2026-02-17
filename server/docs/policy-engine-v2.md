# Policy Engine v2 — IAM for Agent Supervision

For the plain-language product contract, see `oppi-server/docs/llm-iam-principles.md`.

## Problem

The current permission system is binary: allow or deny, one shot. When you approve a browser nav to `x.com`, that approval evaporates. Next time the agent hits `x.com`, you're tapping your phone again. And there's no way to see what you've approved, what rules are in effect, or how decisions were made.

We need a permission system where:
- Approvals can **learn** (add domain to allowlist, remember "always allow git")
- Decisions leave an **audit trail** you can review from your phone
- Rules are **composable** and **scoped** (session, workspace, global)
- The phone is the **management console** — view, add, revoke rules

## Mental Model

Think AWS IAM, but the principal is "your coding agent" and the human is the admin.

| IAM Concept | Agent Equivalent |
|-------------|-----------------|
| Service Control Policy | Hard denies (immutable) |
| Identity Policy | Workspace preset (container, host, restricted) |
| Permission Boundary | Workspace path bounds |
| Resource Policy | Learned/manual rules (domain allowlist, executable allowlist) |
| Session Policy | Session-scoped temp rules |
| CloudTrail | Audit log |

Key principle from IAM: **explicit deny always wins**. Then explicit allow. Then implicit deny (default).

## Resolution Modes

When the phone shows a permission prompt, the user picks *what* to do and *how long* it applies:

| Mode | Scope | Persistence | Example |
|------|-------|-------------|---------|
| Allow once | This invocation | None | "Yes, run this curl" |
| Allow for session | Current session | Memory | "Allow git for this whole session" |
| Allow always | All future sessions | Disk | "Always allow nav to github.com" |
| Deny once | This invocation | None | "No, don't run that" |
| Deny always | All future sessions | Disk | "Never allow rm -rf" |

"Allow always" for browser nav = add domain to `~/.config/fetch/allowed_domains.txt`.
"Allow always" for an executable = add a learned rule to `~/.config/oppi-server/rules.json`.

## Rule Data Model

```typescript
interface PolicyRule {
  id: string;                       // nanoid
  effect: "allow" | "deny";
  
  // What to match (all non-null fields must match)
  tool?: string;                    // "bash", "write", "edit", "*"
  match?: {
    executable?: string;            // "git", "npm", "python3"
    domain?: string;                // "github.com" (browser nav)
    pathPattern?: string;           // "/workspace/**" (file ops)
    commandPattern?: string;        // "git *" (glob against full command)
  };
  
  // Scope
  scope: "session" | "workspace" | "global";
  workspaceId?: string;             // Required for workspace scope
  sessionId?: string;               // Required for session scope
  
  // Metadata
  source: "preset" | "learned" | "manual";
  description: string;              // Human-readable: "Allow git operations"
  risk: RiskLevel;                  // Inherited from the original decision
  createdAt: number;
  createdBy?: string;               // userId who approved
  expiresAt?: number;               // Optional TTL
}
```

## Evaluation Order

```
1. Hard denies (immutable, from preset)         → deny wins immediately
2. Learned/manual deny rules                     → explicit deny beats allow
3. Session rules (temporary, current session)    → nearest scope first
4. Workspace rules (persistent, this workspace)
5. Global rules (persistent, all workspaces)
6. Structural heuristics (pipe-to-shell, data egress, browser parsing)
7. Preset rules (glob-based tool rules)
8. Fetch domain allowlist (shared with fetch skill)
9. Preset default (container=allow, host=ask, restricted=deny)
```

Deny at any layer short-circuits. Allow at layers 3-5 short-circuits (learned rules beat preset defaults). Heuristics and preset rules can still trigger "ask" even if no learned rule matches.

## Audit Log

Every gate decision — auto-allowed, auto-denied, user-approved, timed out — gets logged.

```typescript
interface AuditEntry {
  id: string;
  timestamp: number;
  sessionId: string;
  workspaceId: string;
  userId: string;
  
  // What was requested
  tool: string;
  displaySummary: string;            // Smart summary (e.g., "Navigate: github.com")
  risk: RiskLevel;
  
  // What happened
  decision: "allow" | "deny";
  resolvedBy: "policy" | "user" | "timeout" | "extension_lost";
  layer: string;                      // Which evaluation layer decided
  ruleId?: string;                    // Which rule matched (if any)
  ruleSummary?: string;               // "Browser domain allowlist: github.com"
  
  // What the user chose (if resolvedBy = "user")
  userChoice?: {
    action: "allow" | "deny";
    scope: "once" | "session" | "workspace" | "global";
    learnedRuleId?: string;           // ID of the rule created (if scope != "once")
  };
}
```

Storage: `~/.config/oppi-server/audit.jsonl` — append-only, one JSON object per line. Rotate at 10MB.

## Wire Protocol Changes

### Server → Phone

`permission_request` gets a new `resolutionOptions` field so the phone knows what scopes to offer:

```typescript
{
  type: "permission_request";
  id: string;
  sessionId: string;
  tool: string;
  input: Record<string, unknown>;
  displaySummary: string;
  risk: string;
  reason: string;
  timeoutAt: number;
  
  // NEW: What the user can do beyond allow/deny once
  resolutionOptions: {
    // Can this be allowed for the whole session?
    allowSession: boolean;
    // Can this be allowed permanently?
    allowAlways: boolean;
    // Human-readable description of what "always" means
    alwaysDescription?: string;     // "Add github.com to browser allowlist"
    // Can this be denied permanently?
    denyAlways: boolean;
  };
}
```

### Phone → Server

`permission_response` adds a scope:

```typescript
{
  type: "permission_response";
  id: string;
  action: "allow" | "deny";
  scope: "once" | "session" | "workspace" | "global";
}
```

Server ignores unknown `scope` values (forwards compat). Existing clients that send `{ action: "allow" }` without scope default to `"once"`.

### New: Policy Management Messages

```typescript
// Phone → Server
| { type: "get_policy_rules"; scope?: "session" | "workspace" | "global" }
| { type: "add_policy_rule"; rule: Omit<PolicyRule, "id" | "createdAt"> }
| { type: "remove_policy_rule"; ruleId: string }
| { type: "get_audit_log"; limit?: number; before?: number; sessionId?: string }
| { type: "get_domain_allowlist" }
| { type: "add_domain"; domain: string }
| { type: "remove_domain"; domain: string }

// Server → Phone
| { type: "policy_rules"; rules: PolicyRule[] }
| { type: "policy_rule_added"; rule: PolicyRule }
| { type: "policy_rule_removed"; ruleId: string }
| { type: "audit_log"; entries: AuditEntry[] }
| { type: "domain_allowlist"; domains: string[] }
| { type: "domain_added"; domain: string }
| { type: "domain_removed"; domain: string }
```

## Storage Layout

```
~/.config/oppi-server/
├── rules.json                # Learned + manual rules (global + workspace)
├── audit.jsonl               # Append-only audit log
└── ...

~/.config/fetch/
└── allowed_domains.txt       # Shared browser/fetch domain allowlist (unchanged)
```

Session-scoped rules are in-memory only (die with the session).

## Server-Side Changes

### PolicyEngine additions

```typescript
class PolicyEngine {
  // Existing
  evaluate(req: GateRequest): PolicyDecision;
  formatDisplaySummary(req: GateRequest): string;
  
  // New
  evaluateWithRules(req: GateRequest, rules: PolicyRule[], sessionId: string, workspaceId: string): PolicyDecision;
  getResolutionOptions(req: GateRequest, decision: PolicyDecision): ResolutionOptions;
  
  // New: Smart rule generation from an approval
  suggestRule(req: GateRequest, scope: string): PolicyRule;
}
```

`suggestRule` is the key method — it takes a gate request and produces a sensible rule:

| Request | Suggested Rule |
|---------|---------------|
| nav.js to github.com | `{ tool: "bash", match: { domain: "github.com" }, effect: "allow" }` |
| `git push origin main` | `{ tool: "bash", match: { executable: "git" }, effect: "allow" }` |
| `npm install foo` | `{ tool: "bash", match: { executable: "npm" }, effect: "allow" }` |
| eval.js `document.title` | `{ tool: "bash", match: { domain: <last nav domain> }, effect: "allow" }` — eval inherits the domain context |
| Write to `/workspace/foo.txt` | `{ tool: "write", match: { pathPattern: "/workspace/**" }, effect: "allow" }` |

### RuleStore

New class — manages learned rules, loads/saves `rules.json`, supports scoped queries.

```typescript
class RuleStore {
  constructor(path: string);
  
  add(rule: PolicyRule): PolicyRule;       // Returns rule with generated id
  remove(id: string): boolean;
  
  // Query
  getAll(): PolicyRule[];
  getForSession(sessionId: string): PolicyRule[];
  getForWorkspace(workspaceId: string): PolicyRule[];
  getGlobal(): PolicyRule[];
  
  // Find matching rules for a request
  findMatching(req: GateRequest, sessionId: string, workspaceId: string): PolicyRule[];
  
  // Session lifecycle
  clearSessionRules(sessionId: string): void;
}
```

### AuditLog

```typescript
class AuditLog {
  constructor(path: string);
  
  record(entry: Omit<AuditEntry, "id" | "timestamp">): AuditEntry;
  query(opts: { limit?: number; before?: number; sessionId?: string }): AuditEntry[];
  
  // Maintenance
  rotate(): void;   // Called periodically, rotates at 10MB
}
```

### GateServer changes

`resolveDecision` signature expands:

```typescript
resolveDecision(requestId: string, action: "allow" | "deny", scope?: string): boolean;
```

When `scope` is `"session"` / `"workspace"` / `"global"`:
1. `suggestRule()` generates the rule from the pending decision
2. `RuleStore.add()` persists it
3. If it's a browser domain + global scope → also append to `allowed_domains.txt`
4. Audit log records the decision + learned rule ID

## iOS Changes

### Permission Sheet

The sheet already shows tool + summary + risk. Add resolution buttons:

```
┌─────────────────────────────┐
│  Navigate: evil.example.org │
│  ⚠️ medium — unlisted domain │
│                             │
│  [Deny]  [Allow Once]       │
│  [Allow for Session]        │
│  [Always Allow ↓]           │
│    "Add evil.example.org    │
│     to domain allowlist"    │
└─────────────────────────────┘
```

For critical risk: only "Allow Once" (no permanent learns). For low risk with a clear domain/executable: "Always Allow" is prominent.

### New: Policy Tab

A new tab (or section in settings) for rule/allowlist management:

```
Policy
├── Rules (12)
│   ├── Allow git (global, learned)
│   ├── Allow npm (workspace: pios, manual)
│   ├── Deny rm -rf (global, manual)
│   └── ...
├── Domain Allowlist (56)
│   ├── github.com
│   ├── docs.python.org
│   ├── x.com
│   └── ...
└── Audit Log
    ├── 11:42 — Navigate: x.com/mitsuhiko → allowed (domain allowlist)
    ├── 11:41 — JS: document.title → allowed by user (once)
    ├── 11:40 — git push → allowed (learned rule: git)
    └── ...
```

### SwiftUI Models

```swift
struct PolicyRule: Identifiable, Codable, Sendable {
    let id: String
    let effect: String           // "allow" | "deny"
    let tool: String?
    let match: RuleMatch?
    let scope: String            // "session" | "workspace" | "global"
    let source: String           // "preset" | "learned" | "manual"
    let description: String
    let risk: String
    let createdAt: Date
}

struct RuleMatch: Codable, Sendable {
    var executable: String?
    var domain: String?
    var pathPattern: String?
    var commandPattern: String?
}

struct AuditEntry: Identifiable, Codable, Sendable {
    let id: String
    let timestamp: Date
    let sessionId: String
    let displaySummary: String
    let risk: String
    let decision: String
    let resolvedBy: String
    let ruleSummary: String?
}
```

## Implementation Phases

### Phase 1: Learn from approvals (server only)
- Add `RuleStore` class
- Add `AuditLog` class  
- Expand `resolveDecision` to accept scope
- Implement `suggestRule()` for bash executables + browser domains
- Wire "global" scope to append to `allowed_domains.txt`
- Add `resolutionOptions` to `permission_request` messages
- Backwards-compatible: old clients still work (scope defaults to "once")

### Phase 2: iOS resolution UI
- Update `Permission.swift` with `ResolutionOptions`
- Update `PermissionSheet` with scope buttons
- Update wire protocol handling in `ServerConnection`

### Phase 3: Policy management API
- Add `get_policy_rules` / `add_policy_rule` / `remove_policy_rule` messages
- Add `get_audit_log` message
- Add domain allowlist management messages

### Phase 4: iOS Policy tab
- `PolicyView` with rules list, domain list, audit log
- Swipe-to-delete rules
- Add manual rules
- Search/filter audit log

## Design Decisions

**Why share `allowed_domains.txt` with the fetch skill?**
One allowlist to rule them all. If you trust github.com for fetching docs, you trust it for browsing. Different tools, same trust decision. No list drift.

**Why JSONL for audit, JSON for rules?**
Rules are read-modify-write (small, fits in memory). Audit is append-only, potentially large. JSONL is append-friendly and survives partial writes.

**Why session-scoped rules are in-memory only?**
Sessions are ephemeral. Persisting session rules creates ghosts — rules that reference dead sessions. In-memory means they auto-clean.

**Why no "workspace" scope for browser domains?**
Browser domains are inherently global trust decisions. If you trust x.com in one workspace, you trust it in all of them. The fetch skill doesn't scope by workspace either.

**Why limit "always" for critical risk?**
A critical-risk command (credential exfil, privilege escalation) getting permanently auto-allowed defeats the purpose. You can allow once, or allow for the session, but you have to see it every time across sessions.

**Why `suggestRule()` instead of just storing the raw command?**
Raw commands are fragile. `git push origin main` != `git push origin feat/foo`. The suggested rule generalizes: `{ executable: "git" }` covers all git operations. The user can narrow it later from the policy tab.

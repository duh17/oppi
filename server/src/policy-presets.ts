import type { RuleDecision, RuleInput } from "./rules.js";
import type {
  PolicyConfig as DeclarativePolicyConfig,
  PolicyPermission as DeclarativePolicyPermission,
  PolicyHeuristics,
  PolicyMatch as DeclarativePolicyMatch,
} from "./types.js";
import type {
  CompiledPolicy,
  PolicyAction,
  PolicyRule,
  ResolvedHeuristics,
} from "./policy-types.js";

function mapDecisionToAction(decision: "allow" | "ask" | "block"): PolicyAction {
  if (decision === "block") return "deny";
  return decision;
}

function mapDecisionToRuleDecision(decision: "allow" | "ask" | "block"): RuleDecision {
  if (decision === "block") return "deny";
  return decision;
}

function mapMatchPattern(match: DeclarativePolicyMatch): string | undefined {
  if (typeof match.commandMatches === "string" && match.commandMatches.trim().length > 0) {
    return match.commandMatches.trim();
  }

  if (typeof match.pathMatches === "string" && match.pathMatches.trim().length > 0) {
    return match.pathMatches.trim();
  }

  if (typeof match.pathWithin === "string" && match.pathWithin.trim().length > 0) {
    const base = match.pathWithin.trim().replace(/\/+$/, "");
    return `${base}/**`;
  }

  return undefined;
}

function mapPermissionToRule(permission: DeclarativePolicyPermission): PolicyRule {
  const match = permission.match;

  return {
    tool: match.tool,
    exec: match.executable,
    pattern: mapMatchPattern(match),
    pathWithin: match.pathWithin,
    domain: match.domain,
    action: mapDecisionToAction(permission.decision),
    label: permission.label || permission.reason,
  };
}

function mapPermissionToRuleInput(permission: DeclarativePolicyPermission): RuleInput | null {
  const match = permission.match;
  const tool =
    typeof match.tool === "string" && match.tool.trim().length > 0 ? match.tool.trim() : "*";
  const executable =
    typeof match.executable === "string" && match.executable.trim().length > 0
      ? match.executable.trim()
      : undefined;
  const pattern = mapMatchPattern(match);

  if (tool === "*" && !pattern && !executable) {
    return null;
  }

  return {
    tool,
    decision: mapDecisionToRuleDecision(permission.decision),
    pattern,
    executable,
    label: permission.label || permission.reason,
    scope: "global",
    source: "preset",
  };
}

/** Default heuristic settings (used when heuristics field is omitted from config). */
const DEFAULT_HEURISTICS: ResolvedHeuristics = {
  pipeToShell: "ask",
  dataEgress: "ask",
  secretEnvInUrl: "ask",
  secretFileAccess: "deny",
};

function resolveHeuristics(h?: PolicyHeuristics): ResolvedHeuristics {
  if (!h) return { ...DEFAULT_HEURISTICS };
  return {
    pipeToShell: h.pipeToShell === false ? false : mapDecisionToAction(h.pipeToShell || "ask"),
    dataEgress: h.dataEgress === false ? false : mapDecisionToAction(h.dataEgress || "ask"),
    secretEnvInUrl:
      h.secretEnvInUrl === false ? false : mapDecisionToAction(h.secretEnvInUrl || "ask"),
    secretFileAccess:
      h.secretFileAccess === false ? false : mapDecisionToAction(h.secretFileAccess || "block"),
  };
}

export function compileDeclarativePolicy(policy: DeclarativePolicyConfig): CompiledPolicy {
  return {
    name: policy.mode || "declarative",
    hardDeny: policy.guardrails
      .filter((rule) => rule.decision === "block")
      .map(mapPermissionToRule)
      .map((rule) => ({ ...rule, action: "deny" as const })),
    rules: policy.permissions.map(mapPermissionToRule),
    defaultAction: mapDecisionToAction(policy.fallback),
    heuristics: resolveHeuristics(policy.heuristics),
  };
}

/**
 * Convert declarative policy permissions into unified rule-store seeds.
 *
 * This is a one-time bootstrap source. Runtime evaluation reads from RuleStore.
 */
export function policyRulesFromDeclarativeConfig(policy: DeclarativePolicyConfig): RuleInput[] {
  return [...policy.guardrails, ...policy.permissions]
    .map((permission) => mapPermissionToRuleInput(permission))
    .filter((rule): rule is RuleInput => rule !== null);
}

/**
 * RuleStore is the runtime source of truth for allow/ask/deny rules.
 * Keep the policy engine focused on fallback + heuristic behavior only.
 */
export function policyRuntimeConfig(policy: DeclarativePolicyConfig): DeclarativePolicyConfig {
  return {
    ...policy,
    guardrails: [],
    permissions: [],
  };
}

/**
 * Editable global presets seeded into rules.json on first run.
 * These are convenience defaults, not a strict security boundary.
 */
export function defaultPresetRules(): RuleInput[] {
  return policyRulesFromDeclarativeConfig(defaultPolicy());
}

/**
 * Default policy configuration for new servers.
 *
 * Philosophy: allow most local dev work, ask for external/destructive actions,
 * block credential exfiltration and privilege escalation.
 *
 * Structural heuristics (pipe-to-shell, data egress, secret checks)
 * are always active in evaluate() regardless of this config.
 */
export function defaultPolicy(): DeclarativePolicyConfig {
  return {
    schemaVersion: 1,
    mode: "default",
    description:
      "Developer-friendly defaults: allow local work, ask for external/destructive actions, block credential exfiltration.",
    fallback: "allow",
    guardrails: [
      // ── Privilege escalation ──
      {
        id: "block-sudo",
        decision: "block",
        label: "Block sudo",
        reason: "Prevents privilege escalation",
        match: { tool: "bash", executable: "sudo" },
      },
      {
        id: "block-doas",
        decision: "block",
        label: "Block doas",
        reason: "Prevents privilege escalation",
        match: { tool: "bash", executable: "doas" },
      },
      {
        id: "block-su-root",
        decision: "block",
        label: "Block su root",
        reason: "Prevents privilege escalation",
        match: { tool: "bash", commandMatches: "su -*root*" },
      },

      // ── Credential exfiltration ──
      {
        id: "block-auth-json-bash",
        decision: "block",
        label: "Protect API keys (bash)",
        reason: "Prevents reading auth.json via bash",
        match: { tool: "bash", commandMatches: "*auth.json*" },
      },
      {
        id: "block-auth-json-read",
        decision: "block",
        label: "Protect API keys (read)",
        reason: "Prevents reading auth.json via read tool",
        match: { tool: "read", pathMatches: "**/agent/auth.json" },
      },
      {
        id: "block-printenv-key",
        decision: "block",
        label: "Protect env secrets (_KEY)",
        reason: "Prevents leaking API keys from env",
        match: { tool: "bash", commandMatches: "*printenv*_KEY*" },
      },
      {
        id: "block-printenv-secret",
        decision: "block",
        label: "Protect env secrets (_SECRET)",
        reason: "Prevents leaking secrets from env",
        match: { tool: "bash", commandMatches: "*printenv*_SECRET*" },
      },
      {
        id: "block-printenv-token",
        decision: "block",
        label: "Protect env secrets (_TOKEN)",
        reason: "Prevents leaking tokens from env",
        match: { tool: "bash", commandMatches: "*printenv*_TOKEN*" },
      },
      {
        id: "block-ssh-keys",
        decision: "block",
        label: "Block SSH private key reads",
        reason: "Prevents reading SSH private keys",
        match: { tool: "read", pathMatches: "**/.ssh/id_*" },
      },

      // ── Catastrophic operations ──
      {
        id: "block-root-rm",
        decision: "block",
        label: "Block destructive root delete",
        reason: "Prevents catastrophic filesystem deletion",
        match: { tool: "bash", executable: "rm", commandMatches: "rm -rf /*" },
      },
      {
        id: "block-fork-bomb",
        decision: "block",
        label: "Block fork bomb",
        reason: "Prevents fork bomb denial of service",
        match: { tool: "bash", commandMatches: "*:(){ :|:& };*" },
      },
    ],
    permissions: [
      // ── Destructive local operations → ask ──
      {
        id: "ask-rm-recursive",
        decision: "ask",
        label: "Recursive delete",
        match: { tool: "bash", executable: "rm", commandMatches: "rm *-*r*" },
      },
      {
        id: "ask-rm-force",
        decision: "ask",
        label: "Force delete",
        match: { tool: "bash", executable: "rm", commandMatches: "rm *-*f*" },
      },

      // ── Git external operations → ask ──
      {
        id: "ask-git-push",
        decision: "ask",
        label: "Git push",
        match: { tool: "bash", executable: "git", commandMatches: "git push*" },
      },

      // ── Package publishing → ask ──
      {
        id: "ask-npm-publish",
        decision: "ask",
        label: "npm publish",
        match: { tool: "bash", executable: "npm", commandMatches: "npm publish*" },
      },
      {
        id: "ask-yarn-publish",
        decision: "ask",
        label: "yarn publish",
        match: { tool: "bash", executable: "yarn", commandMatches: "yarn publish*" },
      },
      {
        id: "ask-pypi-upload",
        decision: "ask",
        label: "PyPI upload",
        match: { tool: "bash", executable: "twine", commandMatches: "twine upload*" },
      },

      // ── Remote access → ask ──
      {
        id: "ask-ssh",
        decision: "ask",
        label: "SSH connection",
        match: { tool: "bash", executable: "ssh" },
      },
      {
        id: "ask-scp",
        decision: "ask",
        label: "SCP transfer",
        match: { tool: "bash", executable: "scp" },
      },
      {
        id: "ask-sftp",
        decision: "ask",
        label: "SFTP transfer",
        match: { tool: "bash", executable: "sftp" },
      },

      // ── Raw sockets → ask ──
      {
        id: "ask-nc",
        decision: "ask",
        label: "Netcat connection",
        match: { tool: "bash", executable: "nc" },
      },
      {
        id: "ask-ncat",
        decision: "ask",
        label: "Netcat connection",
        match: { tool: "bash", executable: "ncat" },
      },
      {
        id: "ask-socat",
        decision: "ask",
        label: "Socket relay",
        match: { tool: "bash", executable: "socat" },
      },
      {
        id: "ask-telnet",
        decision: "ask",
        label: "Telnet connection",
        match: { tool: "bash", executable: "telnet" },
      },

      // ── Local machine control → ask ──
      {
        id: "ask-build-install",
        decision: "ask",
        label: "Reinstall iOS app",
        match: { tool: "bash", commandMatches: "*scripts/build-install.sh*" },
      },
      {
        id: "ask-xcrun-install",
        decision: "ask",
        label: "Install app on physical device",
        match: {
          tool: "bash",
          executable: "xcrun",
          commandMatches: "xcrun devicectl device install app*",
        },
      },
      {
        id: "ask-ios-dev-up",
        decision: "ask",
        label: "Restart server and deploy app",
        match: { tool: "bash", commandMatches: "*scripts/ios-dev-up.sh*" },
      },
    ],
    heuristics: {
      pipeToShell: "ask",
      dataEgress: "ask",
      secretEnvInUrl: "ask",
      secretFileAccess: "block",
    },
  };
}

// ── Built-in profiles for explicit mode selection ──
const BUILTIN_CONTAINER_POLICY: CompiledPolicy = {
  name: "container",
  hardDeny: [
    // Privilege escalation — can't escape container, but deny on principle
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo" },
    { tool: "bash", exec: "doas", action: "deny", label: "No doas" },
    { tool: "bash", pattern: "su -*root*", action: "deny", label: "No su root" },

    // Credential exfiltration — API keys are synced into ~/.pi/agent/auth.json
    {
      tool: "bash",
      pattern: "*auth.json*",
      action: "deny",
      label: "Protect API keys",
    },
    {
      tool: "read",
      pattern: "**/agent/auth.json",
      action: "deny",
      label: "Protect API keys",
    },
    {
      tool: "bash",
      pattern: "*printenv*_KEY*",
      action: "deny",
      label: "Protect env secrets",
    },
    {
      tool: "bash",
      pattern: "*printenv*_SECRET*",
      action: "deny",
      label: "Protect env secrets",
    },
    {
      tool: "bash",
      pattern: "*printenv*_TOKEN*",
      action: "deny",
      label: "Protect env secrets",
    },

    // Fork bomb
    {
      tool: "bash",
      pattern: "*:(){ :|:& };*",
      action: "deny",
      label: "Fork bomb",
    },
  ],
  rules: [
    // ── External actions → ask ──

    // Anything that acts on the user's behalf on external services.
    // The user sees these on their phone and approves/denies.
    //
    // Data egress (curl/wget with data flags) is matched structurally
    // in evaluate(), not here. Same for pipe-to-shell.

    // Git write operations (push to remotes)
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*",
      action: "ask",
      label: "Git push",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *add*",
      action: "ask",
      label: "Add git remote",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *set-url*",
      action: "ask",
      label: "Change git remote",
    },

    // Package publishing
    {
      tool: "bash",
      exec: "npm",
      pattern: "npm publish*",
      action: "ask",
      label: "npm publish",
    },
    {
      tool: "bash",
      exec: "npx",
      pattern: "npx *publish*",
      action: "ask",
      label: "npm publish",
    },
    {
      tool: "bash",
      exec: "yarn",
      pattern: "yarn publish*",
      action: "ask",
      label: "yarn publish",
    },
    {
      tool: "bash",
      exec: "pip",
      pattern: "pip *upload*",
      action: "ask",
      label: "pip upload",
    },
    {
      tool: "bash",
      exec: "twine",
      pattern: "twine upload*",
      action: "ask",
      label: "PyPI upload",
    },

    // Remote access (always external)
    { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection" },
    { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer" },
    { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer" },
    { tool: "bash", exec: "rsync", action: "ask", label: "rsync transfer" },

    // Raw sockets
    { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection" },
    { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection" },
    { tool: "bash", exec: "socat", action: "ask", label: "Socket relay" },

    // ── Destructive operations → ask ──
    // These can damage bind-mounted workspace data

    // rm with force/recursive flags
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*r*",
      action: "ask",
      label: "Recursive delete",
    },
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*f*",
      action: "ask",
      label: "Force delete",
    },

    // Git destructive operations
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*--force*",
      action: "ask",
      label: "Force push",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*-f*",
      action: "ask",
      label: "Force push",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git reset --hard*",
      action: "ask",
      label: "Hard reset",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git clean*-*f*",
      action: "ask",
      label: "Git clean",
    },
  ],
  // Preset default behavior
  defaultAction: "allow",
  heuristics: DEFAULT_HEURISTICS,
};

const HOST_HARD_DENY: PolicyRule[] = [
  // Credential exfiltration
  {
    tool: "bash",
    pattern: "*auth.json*",
    action: "deny",
    label: "Protect API keys",
  },
  {
    tool: "read",
    pattern: "**/agent/auth.json",
    action: "deny",
    label: "Protect API keys",
  },
  {
    tool: "bash",
    pattern: "*printenv*_KEY*",
    action: "deny",
    label: "Protect env secrets",
  },
  {
    tool: "bash",
    pattern: "*printenv*_SECRET*",
    action: "deny",
    label: "Protect env secrets",
  },
  {
    tool: "bash",
    pattern: "*printenv*_TOKEN*",
    action: "deny",
    label: "Protect env secrets",
  },

  // Fork bomb
  {
    tool: "bash",
    pattern: "*:(){ :|:& };*",
    action: "deny",
    label: "Fork bomb",
  },
];

const HOST_EXTERNAL_ASK_RULES: PolicyRule[] = [
  // ── Destructive local operations → ask ──
  // Irreversible actions that can damage local data.

  // rm with force/recursive flags
  {
    tool: "bash",
    exec: "rm",
    pattern: "rm *-*r*",
    action: "ask",
    label: "Recursive delete",
  },
  {
    tool: "bash",
    exec: "rm",
    pattern: "rm *-*f*",
    action: "ask",
    label: "Force delete",
  },

  // ── External actions → ask ──
  // Only gate things that act on the user's behalf on external systems.

  // Git push (writes to remotes)
  {
    tool: "bash",
    exec: "git",
    pattern: "git push*",
    action: "ask",
    label: "Git push",
  },

  // Package publishing
  {
    tool: "bash",
    exec: "npm",
    pattern: "npm publish*",
    action: "ask",
    label: "npm publish",
  },
  {
    tool: "bash",
    exec: "yarn",
    pattern: "yarn publish*",
    action: "ask",
    label: "yarn publish",
  },
  {
    tool: "bash",
    exec: "twine",
    pattern: "twine upload*",
    action: "ask",
    label: "PyPI upload",
  },

  // Remote access
  { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection" },
  { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer" },
  { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer" },

  // Raw sockets (can exfiltrate data to arbitrary endpoints)
  { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection" },
  { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection" },
  { tool: "bash", exec: "socat", action: "ask", label: "Socket relay" },
  { tool: "bash", exec: "telnet", action: "ask", label: "Telnet connection" },

  // Local machine control flows (explicit approval required)
  {
    tool: "bash",
    pattern: "*scripts/build-install.sh*",
    action: "ask",
    label: "Reinstall iOS app",
  },
  {
    tool: "bash",
    exec: "xcrun",
    pattern: "xcrun devicectl device install app*",
    action: "ask",
    label: "Install app on physical device",
  },
  {
    tool: "bash",
    pattern: "*scripts/ios-dev-up.sh*",
    action: "ask",
    label: "Restart oppi-server server and deploy app",
  },
  {
    tool: "bash",
    exec: "npx",
    pattern: "npx tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
  },
  {
    tool: "bash",
    exec: "tsx",
    pattern: "tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
  },
];

/**
 * Default local policy mode (developer trust).
 *
 * Philosophy: behave like pi CLI. Tools are mostly free-flowing.
 * The gate asks only for external/high-impact actions and denies secret exfil.
 */
const BUILTIN_HOST_POLICY: CompiledPolicy = {
  name: "default",
  hardDeny: HOST_HARD_DENY,
  rules: HOST_EXTERNAL_ASK_RULES,
  defaultAction: "allow",
  heuristics: DEFAULT_HEURISTICS,
};

export function resolveBuiltInPolicy(mode: string): CompiledPolicy | undefined {
  switch (mode) {
    case "default":
      return BUILTIN_HOST_POLICY;
    case "container":
      return BUILTIN_CONTAINER_POLICY;
    case "host":
      return BUILTIN_HOST_POLICY;
    default:
      return undefined;
  }
}

import { describe, it, expect } from "vitest";
import { PolicyEngine } from "./policy.js";
import type { GateRequest } from "./policy-types.js";
import type { Rule } from "./rules.js";

// ─── Helpers ─────────────────────────────────────────────────────────

let ruleCounter = 0;
function bashRequest(command: string): GateRequest {
  return { tool: "bash", input: { command }, toolCallId: `tc-${ruleCounter++}` };
}

function makeRule(overrides: Partial<Rule> & { tool: string; decision: Rule["decision"] }): Rule {
  return {
    id: `rule-${ruleCounter++}`,
    scope: "global",
    createdAt: Date.now(),
    ...overrides,
  };
}

const SID = "stress-session";
const WID = "stress-workspace";

// ─── The user's actual rule set ──────────────────────────────────────

function userRules(): Rule[] {
  return [
    makeRule({ tool: "bash", decision: "allow", executable: "git", label: "Allow git" }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Git push",
    }),
    makeRule({
      tool: "bash",
      decision: "allow",
      executable: "git",
      pattern: "git commit*",
      label: "Allow git commit",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git reset*",
      label: "Git reset",
    }),
  ];
}

// ─── Stress: compound command permutations ───────────────────────────

describe("stress: compound git commands with mixed allow/ask rules", () => {
  const engine = new PolicyEngine("default");

  // All ways to combine safe + dangerous git commands
  const safeSegments = [
    "git status",
    "git add -A",
    "git add .",
    "git diff --cached",
    "git log --oneline -5",
    "git branch -a",
    "git stash",
    "git stash pop",
    "git fetch origin",
    "git pull origin main",
    "git commit -m 'fix: stuff'",
    "git commit --amend --no-edit",
    "git tag v1.0.0",
  ];

  const dangerousSegments = [
    "git push origin main",
    "git push --force origin main",
    "git push --force-with-lease origin main",
    "git push -f origin main",
    "git push origin main 2>&1 | tail -5",
    "git reset --hard HEAD~1",
    "git reset --hard",
  ];

  const prefixes = [
    "",
    "cd /tmp && ",
    "cd /Users/testuser/workspace/oppi && ",
    "echo starting && ",
    "pwd && ",
    "true && ",
  ];

  // Every dangerous segment should be caught regardless of what safe
  // commands surround it
  for (const dangerous of dangerousSegments) {
    for (const prefix of prefixes) {
      it(`catches: ${prefix}${dangerous}`, () => {
        const cmd = `${prefix}${dangerous}`;
        const result = engine.evaluateWithRules(bashRequest(cmd), userRules(), SID, WID);
        expect(result.action).toBe("ask");
      });
    }

    // Dangerous after safe segments
    for (const safe of safeSegments.slice(0, 5)) {
      it(`catches: ${safe} && ${dangerous}`, () => {
        const cmd = `${safe} && ${dangerous}`;
        const result = engine.evaluateWithRules(bashRequest(cmd), userRules(), SID, WID);
        expect(result.action).toBe("ask");
      });
    }

    // Dangerous before safe segments
    for (const safe of safeSegments.slice(0, 3)) {
      it(`catches: ${dangerous} && ${safe}`, () => {
        const cmd = `${dangerous} && ${safe}`;
        const result = engine.evaluateWithRules(bashRequest(cmd), userRules(), SID, WID);
        expect(result.action).toBe("ask");
      });
    }

    // Dangerous sandwiched between safe segments
    it(`catches: git add -A && ${dangerous} && git status`, () => {
      const cmd = `git add -A && ${dangerous} && git status`;
      const result = engine.evaluateWithRules(bashRequest(cmd), userRules(), SID, WID);
      expect(result.action).toBe("ask");
    });
  }

  // The exact bug-triggering command
  it("catches: cd && add && commit --amend && push --force-with-lease (the original bug)", () => {
    const cmd =
      "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";
    const result = engine.evaluateWithRules(bashRequest(cmd), userRules(), SID, WID);
    expect(result.action).toBe("ask");
    expect(result.ruleLabel).toBe("Git push");
  });

  // Safe-only commands should still be allowed
  for (const safe of safeSegments) {
    it(`allows safe-only: ${safe}`, () => {
      const result = engine.evaluateWithRules(bashRequest(safe), userRules(), SID, WID);
      expect(result.action).toBe("allow");
    });
  }

  // Chains of only safe commands
  it("allows: git add -A && git commit -m 'fix'", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git add -A && git commit -m 'fix: stuff'"),
      userRules(),
      SID,
      WID,
    );
    expect(result.action).toBe("allow");
  });

  it("allows: cd repo && git add . && git commit --amend --no-edit", () => {
    const result = engine.evaluateWithRules(
      bashRequest("cd /tmp/repo && git add . && git commit --amend --no-edit"),
      userRules(),
      SID,
      WID,
    );
    expect(result.action).toBe("allow");
  });
});

// ─── Stress: mixed executable compound commands ──────────────────────

describe("stress: mixed-executable compound commands", () => {
  const engine = new PolicyEngine("default");

  const rules: Rule[] = [
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Git push",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "rm",
      pattern: "rm *-*r*",
      label: "Recursive delete",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "npm",
      pattern: "npm publish*",
      label: "npm publish",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "ssh",
      label: "SSH connection",
    }),
  ];

  const dangerousCommands = [
    { cmd: "git push origin main", label: "Git push" },
    { cmd: "rm -rf ./dist", label: "Recursive delete" },
    { cmd: "npm publish", label: "npm publish" },
    { cmd: "ssh user@host", label: "SSH connection" },
  ];

  const safePrefixes = [
    "npm install",
    "npm test",
    "npm run build",
    "cd /tmp",
    "echo done",
    "ls -la",
    "cat README.md",
    "node -e 'console.log(1)'",
    "python3 -c 'print(1)'",
    "cargo build",
  ];

  for (const { cmd, label } of dangerousCommands) {
    for (const prefix of safePrefixes) {
      it(`catches ${label} after ${prefix.split(" ")[0]}`, () => {
        const result = engine.evaluateWithRules(
          bashRequest(`${prefix} && ${cmd}`),
          rules,
          SID,
          WID,
        );
        expect(result.action).toBe("ask");
      });
    }
  }

  // Multiple dangerous segments — most restrictive wins
  it("catches git push + rm -rf → ask (both ask)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push origin main && rm -rf ./dist"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });

  // Safe commands alone pass through
  for (const safe of safePrefixes) {
    it(`allows: ${safe}`, () => {
      const result = engine.evaluateWithRules(bashRequest(safe), rules, SID, WID);
      expect(result.action).toBe("allow");
    });
  }
});

// ─── Stress: deny rules always dominate ──────────────────────────────

describe("stress: deny rules dominate across segments", () => {
  const engine = new PolicyEngine("default");

  const rules: Rule[] = [
    makeRule({
      tool: "bash",
      decision: "allow",
      executable: "git",
      pattern: "git commit*",
      label: "Allow git commit",
    }),
    makeRule({
      tool: "bash",
      decision: "deny",
      executable: "git",
      pattern: "git push*--force*",
      label: "Deny force push",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Ask git push",
    }),
  ];

  it("deny wins: commit (allow) + force push (deny)", () => {
    const cmd = "git commit --amend --no-edit && git push --force origin main";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
    expect(result.action).toBe("deny");
    expect(result.ruleLabel).toBe("Deny force push");
  });

  it("deny wins: add + commit + force push", () => {
    const cmd = "git add -A && git commit -m 'fix' && git push --force-with-lease origin main";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
    expect(result.action).toBe("deny");
  });

  it("ask (not deny) for normal push after commit", () => {
    const cmd = "git commit --amend --no-edit && git push origin main";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
    expect(result.action).toBe("ask");
    expect(result.ruleLabel).toBe("Ask git push");
  });

  it("allow when only safe commands (commit only)", () => {
    const cmd = "git add . && git commit -m 'fix: it'";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
    expect(result.action).toBe("allow");
  });
});

// ─── Stress: separator variations ────────────────────────────────────

describe("stress: command separator variants", () => {
  const engine = new PolicyEngine("default");
  const rules = userRules();

  const separators = [" && ", " || ", "; ", "\n"];

  for (const sep of separators) {
    const label = sep === "\n" ? "newline" : sep.trim();

    it(`catches push with separator '${label}': cd /tmp${sep}git push origin main`, () => {
      const cmd = `cd /tmp${sep}git push origin main`;
      const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
      expect(result.action).toBe("ask");
    });

    it(`catches push after commit with '${label}'`, () => {
      const cmd = `git commit -m 'fix'${sep}git push origin main`;
      const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
      expect(result.action).toBe("ask");
    });
  }
});

// ─── Stress: pipe within segment ─────────────────────────────────────

describe("stress: pipes within segments (not separators)", () => {
  const engine = new PolicyEngine("default");
  const rules = userRules();

  it("catches git push with pipe to tail", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push origin main 2>&1 | tail -5"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });

  it("catches git push with pipe to grep", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push origin main 2>&1 | grep -i error"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });

  it("catches git push with pipe to tee", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push origin main 2>&1 | tee /tmp/push.log"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });

  it("allows git log with pipe (safe)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git log --oneline | head -10"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("allow");
  });
});

// ─── Stress: quoting edge cases ──────────────────────────────────────

describe("stress: quoting and escaping edge cases", () => {
  const engine = new PolicyEngine("default");
  const rules = userRules();

  it("catches push in: git commit -m 'push to prod' && git push origin main", () => {
    // The word "push" in the commit message should NOT confuse the splitter
    const result = engine.evaluateWithRules(
      bashRequest("git commit -m 'push to prod' && git push origin main"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
    expect(result.ruleLabel).toBe("Git push");
  });

  it("allows: git commit -m 'push to prod' (no actual push)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git commit -m 'push to prod'"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("allow");
  });

  it("catches push with double-quoted message before it", () => {
    const result = engine.evaluateWithRules(
      bashRequest('git commit -m "deploy && push" && git push origin main'),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });
});

// ─── Fuzz: random compound command generation ────────────────────────

describe("fuzz: randomized compound commands", () => {
  const engine = new PolicyEngine("default");
  const rules = userRules();

  const safeCommands = [
    "cd /tmp",
    "git add -A",
    "git add .",
    "git commit -m 'fix'",
    "git commit --amend --no-edit",
    "git status",
    "git log --oneline -5",
    "git diff HEAD",
    "git stash",
    "git branch -a",
    "echo done",
    "pwd",
    "true",
    "ls -la",
    "cat README.md",
    "npm test",
    "npm run build",
  ];

  const askCommands = [
    "git push origin main",
    "git push --force origin main",
    "git push --force-with-lease origin main",
    "git push -f",
    "git reset --hard HEAD~1",
    "git reset --hard",
  ];

  // Use a seeded pseudo-random for reproducibility
  function seededRandom(seed: number): () => number {
    let s = seed;
    return () => {
      s = (s * 1664525 + 1013904223) & 0xffffffff;
      return (s >>> 0) / 0xffffffff;
    };
  }

  const rand = seededRandom(42);

  function pick<T>(arr: T[]): T {
    return arr[Math.floor(rand() * arr.length)];
  }

  // Generate 200 random compound commands with at least one dangerous segment
  for (let i = 0; i < 200; i++) {
    const numSafe = Math.floor(rand() * 4); // 0-3 safe segments
    const segments: string[] = [];

    // Add random safe commands
    for (let j = 0; j < numSafe; j++) {
      segments.push(pick(safeCommands));
    }

    // Insert one dangerous command at a random position
    const dangerous = pick(askCommands);
    const insertAt = Math.floor(rand() * (segments.length + 1));
    segments.splice(insertAt, 0, dangerous);

    // Optionally add another safe command after
    if (rand() > 0.5) {
      segments.push(pick(safeCommands));
    }

    const sep = pick([" && ", " && ", " && ", "; "]); // bias toward &&
    const cmd = segments.join(sep);

    it(`fuzz #${i}: dangerous at pos ${insertAt}/${segments.length} → ask`, () => {
      const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
      expect(result.action).toBe("ask");
    });
  }

  // Generate 100 safe-only compound commands — should all pass
  for (let i = 0; i < 100; i++) {
    const numSegments = 1 + Math.floor(rand() * 4);
    const segments: string[] = [];
    for (let j = 0; j < numSegments; j++) {
      segments.push(pick(safeCommands));
    }
    const sep = pick([" && ", " && ", "; "]);
    const cmd = segments.join(sep);

    it(`fuzz safe #${i}: ${numSegments} safe segments → allow`, () => {
      const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
      expect(result.action).toBe("allow");
    });
  }
});

// ─── Fuzz: multi-dangerous segments ──────────────────────────────────

describe("fuzz: multiple dangerous segments — most restrictive wins", () => {
  const engine = new PolicyEngine("default");

  const rules: Rule[] = [
    makeRule({ tool: "bash", decision: "allow", executable: "git", label: "Allow git" }),
    makeRule({
      tool: "bash",
      decision: "deny",
      executable: "git",
      pattern: "git push*--force*",
      label: "Deny force push",
    }),
    makeRule({
      tool: "bash",
      decision: "deny",
      executable: "git",
      pattern: "git push*-f*",
      label: "Deny force push (-f)",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Ask git push",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git reset*",
      label: "Ask git reset",
    }),
  ];

  // When force push appears anywhere, deny should win
  const forcePushVariants = [
    "git push --force origin main",
    "git push --force-with-lease origin main",
    "git push -f origin main",
  ];

  const otherDangerous = ["git push origin main", "git reset --hard HEAD~1"];

  for (const force of forcePushVariants) {
    for (const other of otherDangerous) {
      it(`deny wins: ${force.slice(0, 30)}... + ${other.slice(0, 30)}...`, () => {
        const cmd = `${other} && ${force}`;
        const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
        expect(result.action).toBe("deny");
      });

      it(`deny wins (reversed): ${other.slice(0, 30)}... + ${force.slice(0, 30)}...`, () => {
        const cmd = `${force} && ${other}`;
        const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
        expect(result.action).toBe("deny");
      });
    }
  }
});

// ─── Edge: empty and degenerate inputs ───────────────────────────────

describe("edge: degenerate inputs", () => {
  const engine = new PolicyEngine("default");
  const rules = userRules();

  it("empty command → default allow", () => {
    const result = engine.evaluateWithRules(bashRequest(""), rules, SID, WID);
    expect(result.action).toBe("allow");
  });

  it("whitespace-only command → default allow", () => {
    const result = engine.evaluateWithRules(bashRequest("   "), rules, SID, WID);
    expect(result.action).toBe("allow");
  });

  it("single semicolons → default allow", () => {
    const result = engine.evaluateWithRules(bashRequest(";;;"), rules, SID, WID);
    expect(result.action).toBe("allow");
  });

  it("cd only → default allow", () => {
    const result = engine.evaluateWithRules(bashRequest("cd /tmp"), rules, SID, WID);
    expect(result.action).toBe("allow");
  });

  it("just && → default allow", () => {
    const result = engine.evaluateWithRules(bashRequest("&&"), rules, SID, WID);
    expect(result.action).toBe("allow");
  });

  it("very long safe command → allow", () => {
    const longPath = "/a" + "/b".repeat(500);
    const result = engine.evaluateWithRules(
      bashRequest(`cd ${longPath} && git status`),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("allow");
  });

  it("very long compound with push at end → ask", () => {
    const segments = Array.from({ length: 50 }, (_, i) => `echo step${i}`);
    segments.push("git push origin main");
    const cmd = segments.join(" && ");
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SID, WID);
    expect(result.action).toBe("ask");
  });
});

// ─── Edge: wildcard tool rules ───────────────────────────────────────

describe("edge: wildcard tool rules", () => {
  const engine = new PolicyEngine("default");

  it("tool='*' rule matches bash commands", () => {
    const rules: Rule[] = [
      makeRule({
        tool: "*",
        decision: "ask",
        pattern: "*push*",
        label: "Wildcard push",
      }),
    ];
    const result = engine.evaluateWithRules(bashRequest("git push origin main"), rules, SID, WID);
    expect(result.action).toBe("ask");
  });

  it("tool='*' in compound: catches push segment", () => {
    const rules: Rule[] = [
      makeRule({
        tool: "*",
        decision: "ask",
        pattern: "*push*",
        label: "Wildcard push",
      }),
    ];
    const result = engine.evaluateWithRules(
      bashRequest("git commit -m 'fix' && git push origin main"),
      rules,
      SID,
      WID,
    );
    expect(result.action).toBe("ask");
  });
});

// ─── Regression: non-bash tools unaffected ───────────────────────────

describe("regression: non-bash tools use existing path (unaffected by refactor)", () => {
  const engine = new PolicyEngine("default");

  it("read tool matches path rule", () => {
    const rules: Rule[] = [
      makeRule({
        tool: "read",
        decision: "ask",
        pattern: "**/secret.txt",
        label: "Read secret",
      }),
    ];
    const req: GateRequest = {
      tool: "read",
      input: { path: "/tmp/secret.txt" },
      toolCallId: "tc-read-1",
    };
    const result = engine.evaluateWithRules(req, rules, SID, WID);
    expect(result.action).toBe("ask");
  });

  it("write tool matches path rule", () => {
    const rules: Rule[] = [
      makeRule({
        tool: "write",
        decision: "deny",
        pattern: "**/config.json",
        label: "Write config",
      }),
    ];
    const req: GateRequest = {
      tool: "write",
      input: { path: "/tmp/config.json" },
      toolCallId: "tc-write-1",
    };
    const result = engine.evaluateWithRules(req, rules, SID, WID);
    expect(result.action).toBe("deny");
  });

  it("edit tool defaults to allow when no rule matches", () => {
    const rules: Rule[] = [];
    const req: GateRequest = {
      tool: "edit",
      input: { path: "/tmp/foo.ts" },
      toolCallId: "tc-edit-1",
    };
    const result = engine.evaluateWithRules(req, rules, SID, WID);
    expect(result.action).toBe("allow");
  });
});

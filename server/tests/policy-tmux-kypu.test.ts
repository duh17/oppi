/**
 * Reproduce: tmux+make command getting blocked in kypu workspace.
 *
 * The command:
 *   SESSION="kdev-$(date +%H%M%S)"; tmux new-session -d -s "$SESSION" \
 *     -c /Users/chenda/workspace/kypu \
 *     'export PATH=$HOME/go/bin:$HOME/.local/bin:$PATH; make d'; \
 *     echo "session=$SESSION"; sleep 6; \
 *     tmux list-sessions | rg "$SESSION"; echo '---'; \
 *     tmux capture-pane -t "$SESSION":0.0 -p -S -120 | tail -n 80
 */

import { describe, it, expect, afterAll } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  PolicyEngine,
  parseBashCommand,
  splitBashCommandChain,
  splitPipelineStages,
  type GateRequest,
} from "../src/policy.js";
import { defaultPresetRules } from "../src/policy-presets.js";
import { RuleStore } from "../src/rules.js";

const tempDirs: string[] = [];

afterAll(() => {
  for (const dir of tempDirs) {
    try {
      rmSync(dir, { recursive: true });
    } catch {
      // ignore
    }
  }
});

function makeTempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "policy-tmux-"));
  tempDirs.push(dir);
  return dir;
}

function makeStore(): RuleStore {
  const dir = makeTempDir();
  const path = join(dir, "rules.json");
  const store = new RuleStore(path);
  store.seedIfEmpty(defaultPresetRules());
  return store;
}

function bash(command: string): GateRequest {
  return { tool: "bash", input: { command }, toolCallId: "t1" };
}

const KYPU_WORKSPACE_ID = "CaDLr396";
const KYPU_SESSION_ID = "test-session";

const FULL_COMMAND = `SESSION="kdev-$(date +%H%M%S)"; tmux new-session -d -s "$SESSION" -c /Users/chenda/workspace/kypu 'export PATH=$HOME/go/bin:$HOME/.local/bin:$PATH; make d'; echo "session=$SESSION"; sleep 6; tmux list-sessions | rg "$SESSION"; echo '---'; tmux capture-pane -t "$SESSION":0.0 -p -S -120 | tail -n 80`;

describe("tmux kypu command — chain splitting", () => {
  it("splits into expected segments (semicolons inside single quotes are preserved)", () => {
    const segments = splitBashCommandChain(FULL_COMMAND);
    console.log("Segments:", segments);

    // The `;` inside 'export PATH=...; make d' should NOT split
    expect(segments).toHaveLength(7);
    expect(segments[0]).toContain("SESSION=");
    expect(segments[1]).toContain("tmux new-session");
    expect(segments[1]).toContain("make d");
    expect(segments[2]).toContain("echo");
    expect(segments[3]).toBe("sleep 6");
    expect(segments[4]).toContain("tmux list-sessions");
    expect(segments[5]).toContain("echo");
    expect(segments[6]).toContain("tmux capture-pane");
  });

  it("parses tmux segment executable correctly", () => {
    const segments = splitBashCommandChain(FULL_COMMAND);
    const tmuxSegment = segments[1];
    const parsed = parseBashCommand(tmuxSegment);
    console.log("tmux segment parsed:", {
      executable: parsed.executable,
      args: parsed.args,
    });
    expect(parsed.executable).toBe("tmux");
  });

  it("parses pipeline stages in segment 5 (tmux list-sessions | rg)", () => {
    const segments = splitBashCommandChain(FULL_COMMAND);
    const pipeSegment = segments[4]; // tmux list-sessions | rg "$SESSION"
    const stages = splitPipelineStages(pipeSegment);
    console.log("Pipeline stages:", stages);

    expect(stages).toHaveLength(2);
    for (const stage of stages) {
      const parsed = parseBashCommand(stage);
      console.log(`  Stage executable: ${parsed.executable}, args:`, parsed.args);
    }
  });

  it("parses pipeline stages in segment 7 (tmux capture-pane | tail)", () => {
    const segments = splitBashCommandChain(FULL_COMMAND);
    const pipeSegment = segments[6]; // tmux capture-pane ... | tail -n 80
    const stages = splitPipelineStages(pipeSegment);
    console.log("Pipeline stages:", stages);

    expect(stages).toHaveLength(2);
    for (const stage of stages) {
      const parsed = parseBashCommand(stage);
      console.log(`  Stage executable: ${parsed.executable}, args:`, parsed.args);
    }
  });
});

describe("tmux kypu command — heuristic checks", () => {
  it("does NOT trigger secretFileAccess heuristic", () => {
    const engine = new PolicyEngine("default");
    const req = bash(FULL_COMMAND);
    const decision = engine.evaluate(req);
    console.log("evaluate() decision:", decision);

    // If this fails, the heuristic is the blocker
    expect(decision.action).not.toBe("deny");
  });

  it("does NOT trigger pipeToShell heuristic", () => {
    // pipeToShell regex: /\|\s*(ba)?sh\b/
    const segments = splitBashCommandChain(FULL_COMMAND);
    for (const segment of segments) {
      const matches = /\|\s*(ba)?sh\b/.test(segment);
      if (matches) {
        console.log("pipeToShell TRIGGERED on:", segment);
      }
      expect(matches).toBe(false);
    }
  });
});

describe("tmux kypu command — full evaluateWithRules", () => {
  it("should ALLOW the full command with default preset rules", () => {
    const store = makeStore();
    const engine = new PolicyEngine("default");
    const rules = store.getAll();
    const req = bash(FULL_COMMAND);

    const decision = engine.evaluateWithRules(req, rules, KYPU_SESSION_ID, KYPU_WORKSPACE_ID);
    console.log("evaluateWithRules decision:", decision);

    if (decision.action !== "allow") {
      // Detailed debug: test each segment individually
      const segments = splitBashCommandChain(FULL_COMMAND);
      for (let i = 0; i < segments.length; i++) {
        const segReq = bash(segments[i]);
        const segDecision = engine.evaluateWithRules(
          segReq,
          rules,
          KYPU_SESSION_ID,
          KYPU_WORKSPACE_ID,
        );
        console.log(`  Segment ${i}: [${segDecision.action}] ${segments[i].slice(0, 80)}`);
        if (segDecision.action !== "allow") {
          console.log(`    Reason: ${segDecision.reason}`);
          console.log(`    Layer: ${segDecision.layer}`);
          console.log(`    Rule: ${segDecision.ruleLabel}`);
          console.log(`    RuleId: ${segDecision.ruleId}`);
        }
      }
    }

    expect(decision.action).toBe("allow");
  });

  it("also tests the .env file read that DID get denied in kypu", () => {
    const store = makeStore();
    const engine = new PolicyEngine("default");
    const rules = store.getAll();

    const envCommand = `cd /Users/chenda/workspace/kypu && rg -n "^KYPU_SQLITE_PATH=" .env .env.example .env.template 2>/dev/null || true`;
    const req = bash(envCommand);
    const decision = engine.evaluateWithRules(req, rules, KYPU_SESSION_ID, KYPU_WORKSPACE_ID);
    console.log(".env command decision:", decision);

    // This SHOULD be denied (confirmed in audit log)
    expect(decision.action).toBe("deny");
    expect(decision.reason).toContain("secret");
  });
});

describe("tmux kypu command — individual segment evaluation", () => {
  const store = makeStore();
  const engine = new PolicyEngine("default");
  const rules = store.getAll();
  const segments = splitBashCommandChain(FULL_COMMAND);

  const segmentNames = [
    "SESSION assignment",
    "tmux new-session (with make d)",
    "echo session",
    "sleep 6",
    "tmux list-sessions | rg",
    "echo ---",
    "tmux capture-pane | tail",
  ];

  for (let i = 0; i < segments.length; i++) {
    it(`segment ${i} (${segmentNames[i] || "?"}) should be allowed`, () => {
      const req = bash(segments[i]);
      const decision = engine.evaluateWithRules(req, rules, KYPU_SESSION_ID, KYPU_WORKSPACE_ID);
      console.log(
        `Segment ${i} [${segmentNames[i]}]: ${decision.action} (${decision.layer}: ${decision.reason})`,
      );

      if (decision.action !== "allow") {
        // Extra debug for failing segment
        const stages = splitPipelineStages(segments[i]);
        for (const stage of stages) {
          const parsed = parseBashCommand(stage);
          console.log(`  Parsed: exec=${parsed.executable}, args=`, parsed.args);
        }
      }

      expect(decision.action).toBe("allow");
    });
  }
});

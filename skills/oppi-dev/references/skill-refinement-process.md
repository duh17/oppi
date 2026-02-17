# Oppi Dev Skill Refinement Process

Run this process before shipping major changes to this skill.

## Step 1 — Load + Inventory

- Read `SKILL.md` end-to-end.
- List `scripts/` and `references/` contents.
- Verify referenced files exist.

## Step 2 — Audit Against Checklist

Use checklist from:
- `~/.claude/skills/skill-creator/references/audit-checklist.md`

Score each item:
- ✅ pass
- ⚠️ warning
- ❌ fail

## Step 3 — Classify Findings

Group issues:

- **Critical**: breaks usage, missing paths, wrong commands, stale scripts.
- **Major**: no default workflow, weak branching, no validation loop.
- **Minor**: wording consistency, optional examples, formatting.

## Step 4 — Apply Fixes

Fix order:
1. Metadata quality (`name`, `description` trigger clarity)
2. Structure (`scripts/`, `references/`, path validity)
3. Single default workflow and decision tree
4. Checklists + validation loops
5. Collaboration output contract

## Step 5 — Validate Tooling

Run command-hub smoke checks:

```bash
{baseDir}/scripts/oppi-workflow.sh help
{baseDir}/scripts/oppi-workflow.sh lookup latest
{baseDir}/scripts/oppi-workflow.sh live status
```

Run at least one lane command to verify composition with repo scripts:

```bash
{baseDir}/scripts/oppi-workflow.sh dev-up -- --no-launch
```

If a command fails due to environment/device availability, record the failure reason and keep the script path + argument shape unchanged.

## Step 6 — Refinement Report

Record:
- checklist summary (Critical/Major/Minor)
- files changed
- validation commands run
- follow-up items

## Current Audit Snapshot

- ✅ Added command-hub default (`scripts/oppi-workflow.sh`)
- ✅ Added composable lane workflow (`references/remote-debug-workflow.md`)
- ✅ Added collaboration output contract in SKILL guidance
- ✅ Preserved existing scripts as underlying primitives (no duplication)
- ✅ Added explicit refinement process document

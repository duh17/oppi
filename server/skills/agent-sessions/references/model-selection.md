# Model and Thinking Selection for Multi-Agent Dispatch

## Default

**Always use `anthropic/claude-opus-4-6` with `high` thinking** unless there's a clear reason to deviate.

## Models

| Model | Strengths | Use when |
|-------|-----------|----------|
| `anthropic/claude-opus-4-6` | Strongest reasoning, best at complex multi-file tasks, architecture, review | Default for everything |
| `anthropic/claude-sonnet-4-6` | Fast, cheaper, good at well-defined tasks | Mechanical refactors, simple test writing, pattern replacements |
| `openai-codex/gpt-5.3-codex` | Strong reasoning, alternative to Opus | When Anthropic models are unavailable or for comparison |

## Thinking levels

| Level | Use when |
|-------|----------|
| `xhigh` | Agent must reason about full codebase structure, dependency graphs, or produce architecture-level documentation |
| `high` | Default. Agent needs to trace complex logic, validate assumptions, or handle edge cases |
| `medium` | Task is well-defined with clear spec and limited scope |
| `low` | Task is purely mechanical (rename, move, format, pattern replace) |

Higher thinking increases response time and token cost but improves quality for complex work.

## Selection patterns

**Architecture / design work** — opus, xhigh
Reads full codebase, reasons about dependency graphs, produces coherent documentation.

**Implementation with spec (default)** — opus, high
TODO has clear requirements and file scope. Read context, implement, verify.

**Mechanical refactor** — sonnet, medium
Well-defined transformation. Speed matters more than depth.

**Exploration / audit (read-only)** — sonnet, medium
Reads code, checks conditions, reports findings. No writes, so mistakes are cheap.

**Code review** — opus, high
Must reason about correctness, architecture compliance, and edge cases.

**Test writing** — opus or sonnet, high or medium
Must understand code under test and design meaningful assertions.

## Multi-agent vs single session

Single sessions degrade over time due to context pollution (useful info buried under noisy output) and context rot (performance drops as conversation fills with less relevant details).

Multi-agent workflows fix this:
- Main agent stays focused on requirements, decisions, orchestration.
- Sub-agents handle noisy work (exploration, tests, log analysis) in isolated contexts.
- Summaries flow back instead of raw intermediate output.

**Rule of thumb:** Parallel agents for read-heavy tasks (exploration, tests, triage). More care with parallel writes — coordination overhead increases.

## Wave pattern

When tasks have dependencies, dispatch in waves:

```
Wave 1: [A] + [B] + [C]    parallel, independent
  -- review, merge, verify --
Wave 2: [D] + [E] + [F]    parallel, depend on wave 1 output
  -- review, merge, verify --
Wave 3: [G]                 depends on wave 2
```

Each wave: disjoint file sets within the wave. Between waves: review commits, run tests, close TODOs.

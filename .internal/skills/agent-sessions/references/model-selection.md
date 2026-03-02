# Model and Thinking Selection for Multi-Agent Dispatch

## Models

| Model | Strengths | Use when |
|-------|-----------|----------|
| `openai-codex/gpt-5.3-codex` | Strongest reasoning, best at complex multi-file tasks | Architecture, design, code review, security, ambiguous requirements |
| `openai-codex/gpt-5.3-codex-spark` | Fast, cheaper, good at read-heavy work | Exploration, scans, summarization, log triage, test runs |
| `anthropic/claude-sonnet-4-6` | Balanced reasoning and speed | Standard implementation, test writing, moderate complexity |

## Thinking levels

| Level | Use when |
|-------|----------|
| `xhigh` | Agent must reason about full codebase structure, dependency graphs, or produce architecture-level documentation |
| `high` | Agent needs to trace complex logic, validate assumptions, or handle edge cases (review, security, multi-step impl) |
| `medium` | Balanced default for most implementation and test-writing tasks |
| `low` | Task is mechanical and well-defined (rename, move, format, pattern replace) |

Higher thinking increases response time and token cost but improves quality for complex work.

## Selection patterns

**Architecture / design work** — codex-5.3, xhigh
Reads full codebase, reasons about dependency graphs, produces coherent documentation.

**Implementation with clear spec** — codex-5.3 or sonnet, medium-high
TODO has clear requirements and file scope. Read context, implement, verify.

**Mechanical refactor** — spark or sonnet, low-medium
Well-defined transformation. Speed matters more than depth.

**Exploration / audit (read-only)** — spark, medium
Reads code, checks conditions, reports findings. No writes, so mistakes are cheap.

**Code review** — codex-5.3, high
Must reason about correctness, architecture compliance, and edge cases.

**Test writing** — sonnet or codex-5.3, medium
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

---
name: jro-fable
description: >-
  Maximize Fable 5 judgment while minimizing token cost. Auto-triggers on
  token-heavy tasks running on Fable: large repo scans, multi-file changes,
  log analysis, broad research, vault audits, transcript processing.
  Routes bounded work to Sonnet/Haiku subagents; keeps architecture,
  synthesis, and final review on Fable. Check whether the task genuinely
  requires Fable-tier reasoning before invoking — if Sonnet or Opus
  suffices, skip the orchestration layer.
  Trigger phrases: jro fable, efficient fable, save tokens, delegate,
  fan out, orchestrate, too expensive, token budget.
author: Jon Orozco
user-invokable: true
updated: 26-0611
---

# JRO-Fable

Fable 5 costs $10/$50 per MTok — 2x Opus, 3.3x Sonnet, 10x Haiku.
Every token Fable spends reading files, scanning repos, or reducing logs
is 10x what Haiku would charge for the same work. Spend Fable tokens on
judgment. Spend cheaper tokens on everything else.

## Pre-flight

Before orchestrating, ask: does this task actually need Fable? If Sonnet
or Opus can handle it end-to-end, use that model directly — no
orchestration layer needed. This skill only applies when the task
genuinely requires Fable-tier reasoning AND has delegatable subtasks.

## Model Routing Table

| Work type | Model | Why |
|---|---|---|
| File search, grep, directory listing, log scanning | `model: "haiku"` | Pattern matching, no reasoning needed. 10x cheaper. |
| Inventory / summarize a codebase or doc set | `model: "haiku"` | Bulk reading with structured extraction. |
| Bounded edits (≤3 files, known scope) | `model: "sonnet"` | Good code generation at 3.3x cheaper. |
| Multi-file implementation, refactoring | `model: "sonnet"` | 79.6% SWE-bench. Right capability/cost balance. |
| Test execution, browser checks, log reduction | `model: "sonnet"` | Fable decides direction; Sonnet executes and reports. |
| Security review, deep code analysis | `model: "sonnet"` | Adequate for most review; Fable re-checks high-impact findings. |
| Task decomposition, architecture, tradeoffs | **Fable (self)** | This is what you're paying for. |
| Conflict resolution across subagent reports | **Fable (self)** | Cross-cutting judgment. |
| Final diff review, risk assessment, user synthesis | **Fable (self)** | Truth-judgment stays here. |

**Haiku breaks even only if its error rate stays below 20%.** If a Haiku
agent's output requires Sonnet-level correction more than 1 in 5 times,
the re-prompting cost negates the savings. Monitor and escalate.

## How to Delegate

Use the `Agent` tool with the `model` parameter:

```
Agent({
  description: "Scan repo for auth patterns",
  model: "haiku",
  prompt: "Search /path/to/repo for authentication..."
})
```

For parallel independent work, send multiple Agent calls in a single
message — they run concurrently (capped at ~16).

For structured multi-stage work, use the `Workflow` tool with
`pipeline()` (no barrier, items flow through stages independently)
or `parallel()` (barrier, waits for all before proceeding).

**Subagents cannot spawn subagents** — this is enforced. If you need
hierarchical delegation, use Workflows.

## Output Contracts

Every subagent prompt must specify the return format. Subagent results
inject into Fable's context verbatim — uncontrolled prose wastes tokens.

See [DELEGATION.md](DELEGATION.md) for named presets with output
contracts for each delegation type.

**General rules for all subagent returns:**
- Max 500 tokens unless the task explicitly requires more.
- Structured over prose: paths, line numbers, commands, pass/fail.
- End with `STOP_REASON:` (scope-complete | hit-stop-condition | ambiguous).
- End with `UNCERTAINTY:` if any doubt about the findings.

## Handoff Packets

Write delegated prompts as if the subagent just walked into the room.
Include only:

- Repo path and exact objective.
- Files/packages in scope. Anything explicitly out of scope.
- Evidence format to return (reference the output contract).
- Verification commands or browser flows, plus what success looks like.
- Stop conditions: if the code doesn't match, a command fails after
  reasonable retry, or the task needs out-of-scope files — stop and
  report instead of improvising.

**Pass relevant file slices, not re-read instructions.** If you already
have a file in context, include the relevant lines in the prompt rather
than asking the subagent to re-read it — that's double-paying for the
same tokens.

## When NOT to Delegate

Delegation has overhead: the routing turn costs Fable tokens, and the
return packet consumes context. Not every task pays off.

**Keep on Fable when:**
- Task is ≤2 tool calls — just do it.
- Files are already in your context — re-reading in a subagent wastes tokens.
- Every edit step requires a judgment call — coordination cost exceeds savings.
- Scope is ambiguous enough that the handoff packet needs full context anyway.
- Single-file bug with obvious root cause — the round trip adds no value.
- The task output is <500 tokens of Sonnet work — routing overhead ≈ savings.

**Delegation break-even rule:** Subagent work should consume 2K+ tokens
to justify the routing overhead. Below that, do it directly.

## Vetting Delegated Work

Treat subagent reports as leads, not facts. Before using a high-impact
finding, opening a PR, or telling the user the work is done:

1. Reopen the important cited files yourself.
2. Confirm line references and failure reports match reality.
3. Review the final diff against the original task.

Let lighter agents gather signal. Keep truth-judgment with Fable.

## Common Scenarios

Treat as soft defaults, not rigid rules:

- **Research**: Haiku agents scan docs, repos, APIs. Fable decides what
  evidence changes the plan.
- **Coding**: Sonnet agents do bounded edits or candidate patches. Fable
  owns shared-file coordination, integration, and final review.
- **Testing**: Fable chooses the validation direction. Sonnet agents run
  tests, browser flows, screenshots, and log reduction. They report
  commands, failures, likely causes, and whether failures look flaky,
  environmental, or real.
- **Debugging**: Haiku/Sonnet agents cluster logs, reproduce issues, try
  small fixes. Fable picks the most trustworthy diagnosis.
- **Audits**: Haiku agents inventory and scan in parallel batches. Fable
  synthesizes findings and makes merge/restructure decisions.

## Cost Reference

| Model | Input/MTok | Output/MTok | vs Fable |
|---|---|---|---|
| Fable 5 | $10.00 | $50.00 | 1x |
| Opus 4.8 | $5.00 | $25.00 | 2x cheaper |
| Sonnet 4.6 | $3.00 | $15.00 | 3.3x cheaper |
| Haiku 4.5 | $1.00 | $5.00 | 10x cheaper |

**Worked example**: 10 research subagent calls, 2K input + 500 output each.

| Setup | Cost | Savings |
|---|---|---|
| All Fable | $0.55 | — |
| Fable orchestrator + Sonnet subagents | $0.24 | 57% |
| Fable orchestrator + Haiku subagents | $0.13 | 76% |

Prompt caching on stable system content (0.1x read price after first
call) compounds these savings further.

## Diagram

Use `assets/fable-orchestrator.excalidraw` when a visual explanation helps.

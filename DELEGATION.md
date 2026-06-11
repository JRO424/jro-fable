# Delegation Presets

Named subagent presets for JRO-Fable. Each preset specifies the
model tier, tool access, and output contract.

## Scout (Haiku)

**Use for**: file search, grep, directory listing, codebase inventory,
log scanning, doc summarization, finding things.

```
Agent({
  description: "Scout: <specific objective>",
  model: "haiku",
  prompt: "<handoff packet — see SKILL.md>"
})
```

**Output contract** (include in every scout prompt):
```
Return ONLY this format, nothing else:

FOUND: <path:line> — <one-line description>
FOUND: <path:line> — <one-line description>
...
COMMANDS_RUN: <list of commands executed>
STOP_REASON: scope-complete | hit-stop-condition | ambiguous
UNCERTAINTY: <anything you're unsure about, or "none">
TOKEN_HINT: kept under 500 tokens
```

**Typical tasks**: "Find all files importing auth middleware",
"List every API endpoint in src/routes/", "Scan these 20 SKILL.md
files and return name + one-line purpose for each".

---

## Builder (Sonnet)

**Use for**: bounded code edits (≤3 files), refactoring with known
scope, implementing a specific function, writing tests for a known
interface.

```
Agent({
  description: "Builder: <specific objective>",
  model: "sonnet",
  prompt: "<handoff packet — see SKILL.md>"
})
```

**Output contract** (include in every builder prompt):
```
Return ONLY this format, nothing else:

CHANGED: <path> — <what changed and why, one line>
CHANGED: <path> — <what changed and why, one line>
VERIFIED: <command run> — pass | fail
DIFF_SUMMARY: <2-3 line summary of the total change>
STOP_REASON: scope-complete | hit-stop-condition | ambiguous
UNCERTAINTY: <anything you're unsure about, or "none">
```

**Fable's responsibility after builder returns**: reopen changed files,
review the diff against the task, verify no scope creep.

---

## Tester (Sonnet)

**Use for**: running test suites, browser checks, screenshot
verification, log reduction, build validation.

```
Agent({
  description: "Tester: <specific objective>",
  model: "sonnet",
  prompt: "<handoff packet — see SKILL.md>"
})
```

**Output contract** (include in every tester prompt):
```
Return ONLY this format, nothing else:

TEST: <test name or command> — pass | fail | flaky | skipped
TEST: <test name or command> — pass | fail | flaky | skipped
...
FAILURES: <count> of <total>
FAILURE_DETAIL: <for each failure: command, output summary, likely cause>
FLAKY_SIGNALS: <if any tests look environmental or timing-dependent>
STOP_REASON: scope-complete | hit-stop-condition | ambiguous
UNCERTAINTY: <anything you're unsure about, or "none">
```

**Fable's responsibility**: decide which failures are real vs
environmental, whether to retry, and whether to block on them.

---

## Reviewer (Sonnet)

**Use for**: code review of a specific diff, security scan of a
bounded surface, documentation accuracy check.

```
Agent({
  description: "Reviewer: <specific objective>",
  model: "sonnet",
  prompt: "<handoff packet — see SKILL.md>"
})
```

**Output contract** (include in every reviewer prompt):
```
Return ONLY this format, nothing else:

FINDING: <path:line> — <severity: bug|risk|nit> — <problem. fix.>
FINDING: <path:line> — <severity: bug|risk|nit> — <problem. fix.>
...
CLEAN: <paths with no findings>
SUMMARY: <total_findings> findings (<bugs> bugs, <risks> risks, <nits> nits)
STOP_REASON: scope-complete | hit-stop-condition | ambiguous
UNCERTAINTY: <anything you're unsure about, or "none">
```

**Fable's responsibility**: re-check any bug-severity findings by
reading the cited files before acting on them.

---

## Workflow Patterns

For multi-stage work with 3+ subagents, use Workflows instead of
individual Agent calls.

**Fan-out research** (parallel scouts):
```javascript
const results = await parallel(
  topics.map(t => () =>
    agent(`Scout: scan for ${t}`, {
      model: "haiku",
      label: `scout:${t}`,
      schema: SCOUT_SCHEMA
    })
  )
);
```

**Pipeline** (each item flows through stages independently):
```javascript
const results = await pipeline(
  items,
  item => agent(`Scout: find ${item}`, { model: "haiku", schema: SCOUT_SCHEMA }),
  (found, item) => agent(`Builder: implement ${item}`, { model: "sonnet", schema: BUILDER_SCHEMA })
);
```

**Use `schema` on agent() calls** to force structured JSON output.
The model retries automatically on schema mismatch — no parsing needed.

---

## Concurrency Limits

- Agent tool: 3-5 concurrent is the practical sweet spot.
- Workflows: 16 concurrent max, 1000 total per run.
- Send independent Agent calls in a single message for parallelism.

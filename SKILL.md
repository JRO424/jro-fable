---
name: jro-fable
description: >-
  Strategic orchestration for top-tier reasoning. Maximizes executive judgment
  and delivery quality while minimizing token spend by keeping decisions on the
  most capable model available and pushing mechanical work downward. Use for
  token-heavy or decision-heavy work: large repo scans, multi-file changes,
  broad research, vault/security audits, transcript processing, product strategy,
  architecture, risk review, executive synthesis, and complex implementation
  planning. Routes mechanical work to cheaper models, keeps judgment on the apex
  model, compresses context aggressively, and verifies before final output.
  Trigger phrases: jro fable, efficient fable, executive mode, save tokens,
  delegate, fan out, orchestrate, command node, too expensive, token budget.
author: Jon Orozco
user-invokable: true
updated: 26-0702
---

# JRO-Fable — Apex-Tier Orchestration

**Mission:** preserve expensive cognition for judgment; push everything else downward.
Information flows **up**. Decisions flow **down**. The apex tier touches decisions, tradeoffs,
synthesis, architecture, and final truth-checking — and nothing mechanical.

---

## Model Binding — the single source of truth

Four tiers. Each binds to the most capable model **available** for its job.
`lib/pricing.json` → `"tiers"` is canonical; this table mirrors it.

| Tier | Owns | Model (as of 26-0702) | Alias / ID |
|---|---|---|---|
| **JUDGMENT** *(apex)* | decisions · architecture · tradeoffs · risk · synthesis · final review | **Fable 5** *(subscription / frontier)* · **Opus 4.8** *(metered-API default)* | `fable` · `claude-fable-5` / `opus` · `claude-opus-4-8` |
| **EXECUTION** | bounded edits · refactors · tests · validation · drafts | **Sonnet 5** | `sonnet` · `claude-sonnet-5` |
| **MECHANICAL** | search · grep · inventory · extraction · log-scan | **Haiku 4.5** | `haiku` · `claude-haiku-4-5-20251001` |
| **LOCAL** *($0 floor)* | bulk extraction · first-pass editorial/code review · embed · classification · drafts · log triage · EN/ES parity | **qwen3 / nomic-embed-text** *(M5 Max, 128 GB)* | `loc` · `lens` · `cr` · `lingua` |

**Resolution rule (auto-correct).** The JUDGMENT seat binds to the first *available* of
`[claude-fable-5, claude-opus-4-8]`. **Fable 5 redeployed 2026-07-01 → the seat now holds Fable 5**,
with one cost-discipline split:

- **Subscription Claude Code** (Jon's normal mode): the main loop already runs Fable 5 at no marginal
  cost. Keep judgment in the main loop; delegate everything mechanical DOWN (Agent/Workflow workers).
- **Metered API** (bench.sh, headless `claude -p` with API key, Queue tasks on API): default judgment
  to **Opus 4.8** ($5/$25, bigger rate pool, no refusal machinery). Escalate to Fable 5 ($10/$50) only
  when frontier-hard: long-horizon agentic work, hardest synthesis, or when Opus disagrees with itself.
  Unattended Fable calls need a refusal fallback (`server-side-fallback-2026-06-01` beta → Opus 4.8).

`lib/pricing.json` → `tiers` stays canonical; change `current` there and re-stamp when anything shifts.

**Fable 5 API mechanics (differ from Opus — matter for scripts/bench):** adaptive thinking is ALWAYS
on (omit the `thinking` param; depth via `output_config.effort`); no prefill; no sampling params; raw
CoT never returned; safety classifiers can return `stop_reason:"refusal"`; 1M context / 128K out; own
smaller rate-limit pool; requires 30-day data retention.

### pxpipe — Fable-5 rate-limit multiplier (opt-in, DL-0025)

For long Fable-5 sessions that would otherwise burn through the smaller Fable rate-limit pool,
`fable-max` routes the session through **pxpipe** (`~/.hermes/node/bin/pxpipe`, daemon
`com.jromac.pxpipe`, dashboard `http://127.0.0.1:47821/`). It renders bulk older-turn text as PNG
pages and pushes them through Fable-5's vision channel — ~3× the char/token density → **~60-70%
fewer input tokens** on Fable traffic. On subscription this converts directly to more Fable work
per rate-limit window.

- **Use for:** long-horizon Fable-5 sessions (research audits, multi-file refactors, long
  multi-tool-result conversations); when hitting the Fable weekly pool early.
- **NEVER for:** sessions handling exact strings that must survive round-tripping — Fable 5 is
  **13/15 exact on dense text** (~87%; safe for prose, **risky for hex / hashes / secrets / IDs**).
  Opus 4.8 is 0/15 exact — pxpipe **automatically passes Opus/Sonnet/Haiku through unchanged**
  (default `PXPIPE_MODELS` scope) so mixed sessions are safe.
- **How:** launch with **`fable-max`** instead of `claude`. Sets `ANTHROPIC_BASE_URL` for that
  process only; no global env pollution. Daemon is always running (launchd `KeepAlive`).
- **Kill switch:** dashboard toggle at `http://127.0.0.1:47821/`, or
  `launchctl unload ~/Library/LaunchAgents/com.jromac.pxpipe.plist`.

> This skill is named `jro-fable` because the judgment seat was originally Fable. The **seat**
> matters, not the label — it always holds the most capable model you can actually call.
> Companion: **`/model-check`** picks the best model for *one* call; **`/jro-fable`** orchestrates a
> job that *spans tiers*. Single call → model-check. Fan-out + synthesis → here.

---

## Core Doctrine

The JUDGMENT tier is **for**: judgment · strategy · architecture · tradeoffs · risk · synthesis ·
final review · executive decisions.

It is **not for**: grep · raw file scanning · directory inventory · log reduction · transcript
extraction · bulk summarization · repetitive edits · test execution · browser checking · formatting.

**If the work does not require a decision, do not spend the apex tier on it.**

## Pre-Flight Gate

Before invoking, answer: (1) What **decision** is needed? (2) What **evidence**? (3) What can a
**cheaper** model do? (4) What context must stay **out** of the apex context? (5) What does **done**
look like?

- No real decision → use EXECUTION or MECHANICAL directly; don't load this skill.
- Under **2 tool calls** → just do it. - Everything already in context → don't delegate unless
  isolation creates clear value.

## The Prime Rule

**Never escalate work to the apex tier until it contains an actual decision.**

| Bad (no decision) | Good (decision) |
|---|---|
| "Analyze these logs." | "Determine the most likely root cause and recommend the safest fix." |
| "Read this repo." | "Identify the architectural constraint blocking multi-tenant isolation." |
| "Summarize this transcript." | "Extract the decisions, risks, owners, and next actions." |

---

## Decision Tiers + Routing

**LOCAL — qwen3 / nomic-embed-text** *($0, on-machine via ~/bin/loc, lens, cr, lingua)*:
bulk extraction · classification · dedup · first-pass editorial QC · first-pass code review ·
EN/ES parity · embedding text for semantic recall · draft prose · log triage · format conversion.
Sub-3s on qwen3:8b, 5–30s on qwen3:32b. **Try LOCAL first** whenever the task is bounded +
verifiable + a Claude correction would be cheap. See [/loc](../loc/SKILL.md).

**MECHANICAL — Haiku 4.5** *(cap 150 tok)*: file search, grep, listing, log scan, field extraction,
inventory, counting, dedup, simple classification, transcript chunking. *Use when LOCAL is
saturated, the task needs tool calls, or LOCAL has shown >20% rework rate on this task type.*
*(No adaptive thinking / effort param on Haiku — extended thinking via budget_tokens only.)*
**EXECUTION — Sonnet 5** *(cap 300 tok)*: bounded edits, refactors, test runs, browser checks, doc
updates, candidate patches, error repro, log interpretation, validation reports. Near-Opus coding at
3-5x less cost (intro $2/$10 through 26-0831); adaptive thinking on by default; own rate pool.
**JUDGMENT — Fable 5 / Opus 4.8** *(as useful)*: architecture, strategic tradeoffs, product/business
decisions, risk calls, final synthesis, conflict resolution, exec recommendations, high-impact review.
Fable 5 in subscription sessions and for frontier-hard work; Opus 4.8 as metered-API default.

## Effort Routing — the second knob (new, Claude 5 family + Opus 4.7+)

`effort` (`low` | `high` | `xhigh` | `max`, default `high`) controls reasoning depth *within* a model.
Two rules change how this stack routes:

1. **Downshift EFFORT before downshifting MODEL on judgment work.** Fable 5 at `low` effort often
   exceeds prior models at `max` — a low-effort apex call can beat a high-effort Sonnet call at
   similar spend, without leaving the cached prefix.
2. **Set effort per worker stage.** Mechanical/extraction workers → `low`. Execution → default.
   The hardest verify/judge stages → `xhigh` (Claude Code's own default). `max` only when
   correctness outweighs cost outright. Higher effort up front often *reduces* total agentic cost
   (fewer correction turns). Workflow `agent()` takes `effort:` directly; Agent-tool workers inherit
   session effort unless the task says otherwise.

**Cache rule that beats model-hopping:** cached reads don't count toward rate limits. Keep the main
loop on ONE model with a stable prefix and spawn cheaper-model subagents — never switch the main
loop's model mid-session (invalidates the cache and re-bills the whole context).

| Work | Default | Reason |
|---|---|---|
| Bulk extraction · classification · dedup · log triage | **`loc fast`** | $0, on-machine, sub-3 s |
| First-pass editorial QC before Jon sees writing | **`lens`** | independent local copywriter |
| First-pass code review before /harden | **`cr`** | qwen3-coder, independent of Claude |
| EN/ES translation + parity check | **`lingua`** | bilingual local editor |
| Embedding text for semantic recall | **`loc embed`** | nomic-embed-text, 768-dim, free |
| Search · grep · inventory · log scan (needs tool calls) | Haiku | mechanical pattern work w/ tools |
| Repo map + dependency listing (cross-file reasoning) | Haiku | context isolation |
| Bounded edits (≤3 files) · multi-file implementation | Sonnet | strong execution, lower cost |
| Testing · browser checks · validation | Sonnet | execution + reporting |
| Security review, first pass | Sonnet | good signal; apex verifies |
| Architecture · strategy · exec synthesis | **apex** (Fable 5 / Opus 4.8) | judgment |
| Final diff review · risk acceptance | **apex** (Fable 5 / Opus 4.8) | truth-check + accountability |
| Frontier-hard: long-horizon agentic · hardest synthesis · Opus-vs-Opus conflict | **Fable 5** | the seat above the seat |
| Interactive latency-bound Opus-grade work (live debugging under deadline) | **Opus 4.8 fast** (`/fast`) | 2.5x speed, 2x price, credits-only on Pro/Max — never autonomous/batch runs |

**Haiku breaks even only if its error rate stays <20%.** If Haiku output needs apex-level correction
more than 1 in 5 times, the re-prompt cost negates the savings — promote that task type up a tier.

## Invocation mechanics

Delegate with the `Agent` tool and an explicit `model`:
```
Agent({ description: "Scan repo for auth patterns", model: "haiku",
        prompt: "<handoff packet — see below>" })
```
Independent calls in **one message** run in parallel (~16 cap). For structured multi-stage fan-out use
the `Workflow` tool — `pipeline()` (no barrier, items flow stage-to-stage) or `parallel()` (barrier).
**Subagents cannot spawn subagents** (enforced) — use Workflows for hierarchy.

---

## Context Budget

- **HOT** — needed now; keep in apex context (exact error · file slice · requirement · final options · critical risk).
- **WARM** — maybe later; compress to **<300 tok** (repo map · transcript summary · research notes · test history).
- **COLD** — not needed; archive/discard after extraction (full logs · transcripts · inventories · raw dumps).

**Rule:** don't carry raw material after extracting facts. Extract signal · discard bulk · keep receipts.

## Evidence Before Analysis

Don't reason while gathering. **Collect → Reduce → Verify → Reason → Decide → Execute → Validate →
Summarize.** If evidence is incomplete, say so; if partial evidence still allows progress, take the
best path and mark the uncertainty.

## Delegation Break-Even

**Delegate when:** the worker reads 2K+ tokens · task is parallelizable · work is mechanical/bounded ·
output compresses tightly · main context would otherwise be polluted.
**Don't when:** under 2 tool calls · files already in context · output shorter than the handoff · every
step needs judgment · scope too ambiguous · the worker would need the whole conversation.

---

## Workers — named, specialized drones (not generic delegation)

Spawn with the model shown + a strict output contract. Every return ends with
`STOP_REASON:` · `CONFIDENCE:` · `UNCERTAINTY:`. (Full presets in `DELEGATION.md`.)

| Worker | Model | Tools | Returns |
|---|---|---|---|
| **Repo Scout** | Haiku | read-only | FILES · PATTERNS · LIKELY_ENTRYPOINTS · RISKS |
| **Log Hunter** | Haiku | read-only | ERROR_CLUSTERS · FIRST_FAILURE · LIKELY_CAUSE · FILES_OR_COMMANDS |
| **Transcript Extractor** | Haiku | read-only | DECISIONS · ACTION_ITEMS · RISKS · OPEN_QUESTIONS · OWNER_MAP |
| **Research Scout** | Haiku/Sonnet | search/read | SOURCES · CLAIMS · CONFLICTS · DATES · RELEVANCE |
| **Patch Builder** | Sonnet | edit/test | FILES_CHANGED · SUMMARY · TESTS_RUN · RESULTS · RISKS · ROLLBACK_NOTES |
| **Test Runner** | Sonnet | terminal/browser | COMMANDS · PASS · FAIL · FLAKY_OR_ENV · LIKELY_CAUSE · NEXT_VERIFICATION |
| **Diff Reviewer** | Sonnet | read-only | BLOCKERS · REGRESSIONS · SECURITY_RISKS · QUALITY_ISSUES · APPROVE_OR_REJECT |
| **Risk Officer** | Sonnet pass → **Opus 4.8** final | read-only | TOP_RISKS · SEVERITY · LIKELIHOOD · MITIGATION · GO_NO_GO |

**Handoff packet (every worker prompt, nothing extra):** exact objective · paths in scope · files
included · files excluded · output contract · token cap · **tool-call budget** · stop conditions ·
success criteria · confidence requirement · the **Worker Discipline Block** (`DELEGATION.md`).
Pass **file slices, not whole files**; never re-read what's already known.

**Stop conditions** (stopping is not failure; improvising out of scope is): required files missing ·
scope expands · commands fail after retry · evidence contradicts the assignment · task needs judgment
above the tier · output exceeds cap · confidence <70.

**Confidence scale:** 90-100 usable w/ spot-check · 70-89 usable w/ verification · 50-69 escalate ·
<50 discard/re-scope.

---

## Escalation

- **Haiku → Sonnet** when: confidence <70 · findings conflict · code modification · nuanced reasoning · drives a high-impact decision.
- **Sonnet → apex (Opus 4.8)** when: architecture affected · security/compliance risk · material business consequences · valid paths conflict · user-facing final judgment · high rework cost.
- **Opus 4.8 → Fable 5** when: months-scale/long-horizon agentic work · two defensible Opus answers conflict and the call is high-stakes · frontier synthesis across domains · Jon explicitly wants the strongest available read. Before escalating, try Opus at `xhigh` effort first — effort is cheaper than the tier jump.

## Verification

Treat worker output as **leads, not facts.** Before any final answer/commit: reopen cited
files/evidence · confirm line refs, commands, failures · review the final diff · validate against the
original request · state remaining uncertainty. High-impact → **adversarial review** (produce
recommendation → a second drone tries to disprove it → compare → decide on the apex tier).

## Token-Saving Rules

Extraction over summarization · bullets over prose · paths+lines over explanation · deltas over full
restatements · contracts over open prompts · archives over context-stuffing · one final synthesis over
repeated mid-level summaries. Never paste raw logs unless exact text matters; never carry full
transcripts after extracting decisions; never let workers return narrative unless required.

---

## Workflows

- **Repo audit:** apex defines question → Repo Scout maps → Haiku drones scan bounded areas in parallel → Sonnet reviews risky findings → apex synthesizes architecture/risk/plan → Sonnet validates → apex finalizes.
- **Multi-file change:** apex defines behavior → Repo Scout finds files → apex picks path → Patch Builder edits → Test Runner validates → Diff Reviewer checks regressions → apex final review.
- **Debugging:** Log Hunter clusters failures → Repo Scout locates code paths → Sonnet reproduces → apex chooses root cause → Sonnet patches → Test Runner validates → apex finalizes.
- **Research:** apex defines question → Research Scouts gather → Haiku extracts claims/dates/conflicts → Sonnet checks source quality → apex synthesizes → cite only load-bearing sources.
- **Transcript/meeting:** Transcript Extractor pulls decisions/owners/risks/open-questions → Haiku compresses notes → apex identifies strategic implications → Sonnet drafts follow-ups → apex reviews.

## Jon Executive Routing

- **Apex (Fable 5 in Claude Code · Opus 4.8 on metered API):** FYHR strategy · EOS operating model · product architecture · investor logic · pricing · board narratives · partnership/franchise/holdco structure · positioning, voice & doctrine · any high-leverage "what should I do?"
- **Sonnet 5:** draft docs · implementation plans · SOPs · checklists · Blue.app buildouts · proposals · internal operating docs · code edits · QA passes.
- **Haiku:** fact extraction from notes · doc search · transcript summaries · finding prior decisions · file inventory · pulling examples · dedup.

---

## Instrumentation (real tooling in `lib/`)

**Cost source of truth:** `lib/pricing.json` (per-MTok prices + `tiers` bindings). Before quoting costs
on a high-value decision, run `lib/pricing-check.sh` — scrapes pricing, reports MATCH/DRIFT/UNKNOWN per
model, does **not** auto-update (verify → edit → re-stamp `last_verified`).

Worked example — 10 calls, 2K in + 500 out each: all-apex (Opus) ≈ $0.21 · apex + Sonnet workers ≈
$0.10 (≈55% off) · apex + Haiku workers ≈ $0.04 (≈80% off). Prompt caching (0.1× read after first call)
compounds it. *(Numbers move with pricing — `pricing.json` is authoritative.)*

**Receipts:** after each delegated call, `lib/log-receipt.sh <model> <task_type> <in> <out> <success>
[notes]` (success: 1 usable / 0 needed correction). Weekly `lib/receipts-digest.sh --since 7d` flags any
task↔model pair with error-rate >20% on n≥5 → promote it a tier.

**Benchmarking:** `lib/bench.sh` runs the model mix on Jon's real task set (repo scan · log reduction ·
transcript extraction · business research · strategy synthesis · draft creation · multi-file patch ·
final review); tracks cost · latency · accuracy · rework · token load · usefulness. `--judge` scores
runs with the apex model. *(Set `ANTHROPIC_API_KEY` for clean timing; OAuth adds ~0.5–2s/call.)*

## Quality Bar — not done until all true

(1) apex did **only** judgment · (2) cheaper models did mechanical work · (3) context compressed ·
(4) evidence verified (files reopened) · (5) uncertainty stated · (6) answer is useful · (7) token
spend proportional to value · (8) work moved Jon closer to execution.

## Final Rule

**Don't optimize for cheap. Optimize for leverage.** The best outcome is the *smallest amount of apex
cognition required to produce a correct, useful, executive-grade result.*

---

## Files

```
~/.claude/skills/jro-fable/
├── SKILL.md            # this file          ├── lib/
├── DELEGATION.md       # worker contracts    │   ├── pricing.json        # prices + tier bindings (SoT)
├── README.md           # install + overview  │   ├── pricing-check.sh    # drift detector
├── install.sh                                │   ├── log-receipt.sh      # one receipt
├── assets/                                   │   ├── receipts-digest.sh  # weekly + break-even warns
│   └── fable-orchestrator.excalidraw         │   └── bench.sh            # benchmark harness
├── data/receipts.jsonl # delegation log      └── benchmarks/tasks/*.txt # canonical prompts
```
Visual: `assets/fable-orchestrator.excalidraw`.

## Changelog

- 26-0706: Added **Worker Discipline Block** to DELEGATION.md (paste-into-every-drone rules:
  tool-call budget, assume-and-continue, ≤30-word status, no future-work promises, no
  comment-scratchpad, injection hygiene for web-facing workers). Distilled from public
  system-prompt corpus (asgeirtj/system_prompts_leaks: ChatGPT agent mode, Gemini CLI, Cursor,
  Codex). Handoff packet now includes tool-call budget + discipline block.
- 26-0702: **Fable 5 takes the JUDGMENT seat** (redeployed 2026-07-01; the resolution rule now
  binds it). Added the subscription-vs-metered-API split (Fable free-in-plan for Claude Code
  judgment; Opus 4.8 stays the metered default with Fable as frontier escalation). EXECUTION seat
  upgraded Sonnet 4.6 → Sonnet 5 (near-Opus coding, intro $2/$10 through 26-0831, adaptive thinking
  default-on, own rate pool). New **Effort Routing** section: effort (low|high|xhigh|max) is the
  intra-model knob; downshift effort before downshifting model on judgment work; per-stage worker
  effort. Added Fable 5 API mechanics (always-on thinking, no prefill, refusal + server-side
  fallback beta, own smaller rate pool, 30-day retention), Opus 4.8 fast-mode row (2.5x speed, 2x
  price, credits-only, interactive-only), cache-over-model-hopping rule, and Opus→Fable escalation
  criteria. pricing.json re-verified against platform.claude.com 2026-07-02 (Opus 4/Sonnet 4
  retired 26-0615; Opus 4.1 retires 26-0805). All facts from official Anthropic docs.

#!/usr/bin/env bash
# log-receipt.sh — append one delegation receipt to data/receipts.jsonl.
#
# Called by /jro-fable after every Agent({model:...}) invocation. Receipts
# accumulate into an empirical record of when delegation paid off and when
# it didn't. Weekly digest (receipts-digest.sh) turns them into routing wisdom.
#
# Usage:
#   log-receipt.sh <model> <task_type> <in_tokens> <out_tokens> <success> [notes]
#
# Args:
#   model       e.g. "haiku", "sonnet", "opus", "fable"
#   task_type   one of: search, summarize, extract, edit, refactor, decompose,
#               review, judge, audit, debug, other
#   in_tokens   integer (estimated or actual)
#   out_tokens  integer (estimated or actual)
#   success     1 = subagent output was usable as-is
#               0 = required Sonnet/Fable correction
#   notes       optional free-text (under 200 chars)
#
# Latency is captured from $RECEIPT_LATENCY_MS env var if set, else null.
# Session id from $CLAUDE_SESSION_ID env var if set, else null.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${SKILL_DIR}/data"
RECEIPTS="${DATA_DIR}/receipts.jsonl"

if [[ $# -lt 5 ]]; then
    cat >&2 <<EOF
Usage: log-receipt.sh <model> <task_type> <in_tokens> <out_tokens> <success> [notes]

  model       haiku | sonnet | opus | fable (or full ID)
  task_type   search | summarize | extract | edit | refactor | decompose |
              review | judge | audit | debug | other
  in_tokens   integer
  out_tokens  integer
  success     1 (used as-is) | 0 (needed correction)
  notes       optional free-text
EOF
    exit 2
fi

model="$1"
task_type="$2"
in_tokens="$3"
out_tokens="$4"
success="$5"
notes="${6:-}"

# Validate numerics
if ! [[ "$in_tokens" =~ ^[0-9]+$ ]] || ! [[ "$out_tokens" =~ ^[0-9]+$ ]]; then
    printf 'log-receipt: in_tokens and out_tokens must be integers\n' >&2
    exit 2
fi
if [[ "$success" != "0" && "$success" != "1" ]]; then
    printf 'log-receipt: success must be 0 or 1\n' >&2
    exit 2
fi

mkdir -p "$DATA_DIR"

ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
session_id="${CLAUDE_SESSION_ID:-}"
latency_ms="${RECEIPT_LATENCY_MS:-}"

# Compute estimated cost from pricing.json (best-effort; never blocks the log)
cost_usd=""
pricing_file="${SCRIPT_DIR}/pricing.json"
if [[ -f "$pricing_file" ]] && command -v jq >/dev/null 2>&1; then
    # Allow short aliases
    case "$model" in
        haiku)  full_id="claude-haiku-4-5-20251001" ;;
        sonnet) full_id="claude-sonnet-4-6" ;;
        opus)   full_id="claude-opus-4-8" ;;
        fable)  full_id="claude-fable-5" ;;
        *)      full_id="$model" ;;
    esac
    in_rate="$(jq -r --arg m "$full_id"  '.models[$m].input_per_mtok_usd  // empty' "$pricing_file" 2>/dev/null)"
    out_rate="$(jq -r --arg m "$full_id" '.models[$m].output_per_mtok_usd // empty' "$pricing_file" 2>/dev/null)"
    if [[ -n "$in_rate" && -n "$out_rate" ]]; then
        # NOTE: /usr/bin/python3 explicitly to bypass the uv shim on PATH that
        # rejects bare `python3` calls (would silently return empty cost).
        cost_usd="$(/usr/bin/python3 -c "print(f'{($in_tokens * $in_rate + $out_tokens * $out_rate) / 1000000:.6f}')" 2>/dev/null || echo "")"
    fi
fi

jq -nc \
    --arg ts "$ts" \
    --arg session_id "$session_id" \
    --arg model "$model" \
    --arg task_type "$task_type" \
    --argjson in_tokens "$in_tokens" \
    --argjson out_tokens "$out_tokens" \
    --argjson success "$success" \
    --arg notes "$notes" \
    --arg latency_ms "$latency_ms" \
    --arg cost_usd "$cost_usd" \
    '{
      ts: $ts,
      session_id: (if $session_id == "" then null else $session_id end),
      model: $model,
      task_type: $task_type,
      in_tokens: $in_tokens,
      out_tokens: $out_tokens,
      success: ($success == 1),
      latency_ms: (if $latency_ms == "" then null else ($latency_ms | tonumber) end),
      cost_usd: (if $cost_usd == "" then null else ($cost_usd | tonumber) end),
      notes: (if $notes == "" then null else $notes end)
    }' >> "$RECEIPTS"

exit 0

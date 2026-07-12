#!/usr/bin/env bash
# receipts-digest.sh — turn data/receipts.jsonl into routing wisdom.
#
# Summarizes: cost by model, error rate by (model, task_type), break-even
# warnings when Haiku error rate breaches the 20% threshold from SKILL.md,
# and top "delegate didn't pay off" sessions.
#
# Usage:
#   receipts-digest.sh                 # full digest, all-time
#   receipts-digest.sh --since 7d      # last 7 days
#   receipts-digest.sh --since YYYY-MM-DD
#   receipts-digest.sh --json          # machine-readable

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
RECEIPTS="${SKILL_DIR}/data/receipts.jsonl"

SINCE=""
JSON_MODE=0
i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        --since) i=$((i+1)); SINCE="${!i:-}" ;;
        --json)  JSON_MODE=1 ;;
        --help)  sed -n '2,15p' "$0"; exit 0 ;;
    esac
    i=$((i+1))
done

# Resolve --since
if [[ -n "$SINCE" ]]; then
    if [[ "$SINCE" =~ ^([0-9]+)d$ ]]; then
        days="${BASH_REMATCH[1]}"
        SINCE_ISO="$(date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                     date -u -d "${days} days ago" '+%Y-%m-%dT%H:%M:%SZ')"
    else
        SINCE_ISO="${SINCE}T00:00:00Z"
    fi
else
    SINCE_ISO="1970-01-01T00:00:00Z"
fi

if [[ ! -f "$RECEIPTS" ]]; then
    printf 'receipts-digest: no receipts logged yet at %s\n' "$RECEIPTS"
    printf '  /jro-fable will start logging after the SKILL.md changes take effect.\n'
    exit 0
fi

TOTAL_COUNT="$(wc -l < "$RECEIPTS" | tr -d ' ')"
if [[ "$TOTAL_COUNT" -eq 0 ]]; then
    printf 'receipts-digest: receipts.jsonl exists but is empty.\n'
    exit 0
fi

# Filter to window
FILTERED="$(jq -c --arg since "$SINCE_ISO" 'select(.ts >= $since)' "$RECEIPTS")"
WINDOW_COUNT="$(printf '%s\n' "$FILTERED" | grep -c . || echo 0)"

if [[ "$WINDOW_COUNT" -eq 0 ]]; then
    printf 'receipts-digest: no receipts since %s.\n' "$SINCE_ISO"
    exit 0
fi

# ---- Aggregate ----
# By model: count, total in/out tokens, total cost, success rate, avg latency
BY_MODEL="$(printf '%s\n' "$FILTERED" | jq -s '
    group_by(.model) | map({
        model: .[0].model,
        n: length,
        in_tokens_sum: (map(.in_tokens) | add),
        out_tokens_sum: (map(.out_tokens) | add),
        cost_usd_sum: (map(.cost_usd // 0) | add),
        success_rate: (([.[] | select(.success == true)] | length) / length),
        avg_latency_ms: ((map(.latency_ms // 0) | add) / length)
    })')"

# By task_type × model: error rate
BY_TASK_MODEL="$(printf '%s\n' "$FILTERED" | jq -s '
    group_by(.task_type + "|" + .model) | map({
        task_type: .[0].task_type,
        model: .[0].model,
        n: length,
        success_rate: (([.[] | select(.success == true)] | length) / length),
        error_rate: (([.[] | select(.success == false)] | length) / length)
    })')"

# Break-even warnings: any (haiku|sonnet) row with error_rate > 0.20 AND n >= 5
WARNINGS="$(printf '%s' "$BY_TASK_MODEL" | jq '[.[] | select((.model | test("haiku|sonnet")) and .error_rate > 0.20 and .n >= 5)]')"

if [[ "$JSON_MODE" == "1" ]]; then
    jq -nc \
        --arg since "$SINCE_ISO" \
        --argjson total_all_time "$TOTAL_COUNT" \
        --argjson window_count "$WINDOW_COUNT" \
        --argjson by_model "$BY_MODEL" \
        --argjson by_task_model "$BY_TASK_MODEL" \
        --argjson warnings "$WARNINGS" \
        '{since: $since, total_all_time: $total_all_time, window_count: $window_count,
          by_model: $by_model, by_task_model: $by_task_model, warnings: $warnings}'
    exit 0
fi

# ---- Human-readable digest ----
printf '\n┌─ /jro-fable receipts digest ─────────────────────────────────\n'
printf '│ window: since %s\n' "$SINCE_ISO"
printf '│ entries in window: %d   |   all-time: %d\n' "$WINDOW_COUNT" "$TOTAL_COUNT"
printf '└──────────────────────────────────────────────────────────────\n\n'

printf 'BY MODEL\n'
printf '  %-12s  %5s  %9s  %9s  %8s  %7s  %8s\n' \
    "model" "n" "in_tok" "out_tok" "cost_$" "succ%" "lat_ms"
printf '  %-12s  %5s  %9s  %9s  %8s  %7s  %8s\n' \
    "-----" "-" "------" "-------" "------" "-----" "------"
printf '%s\n' "$BY_MODEL" | jq -r '.[] | [
    .model,
    (.n | tostring),
    (.in_tokens_sum | tostring),
    (.out_tokens_sum | tostring),
    (.cost_usd_sum * 100 | round / 100 | tostring),
    ((.success_rate * 100) | round | tostring),
    (.avg_latency_ms | round | tostring)
] | @tsv' | awk -F'\t' '{printf "  %-12s  %5s  %9s  %9s  %8s  %7s  %8s\n", $1,$2,$3,$4,"$"$5,$6"%",$7}'

printf '\nBY TASK_TYPE × MODEL  (n >= 3 only)\n'
printf '  %-12s  %-12s  %5s  %8s\n' "task_type" "model" "n" "err_rate"
printf '  %-12s  %-12s  %5s  %8s\n' "---------" "-----" "-" "--------"
printf '%s\n' "$BY_TASK_MODEL" | jq -r '
    .[] | select(.n >= 3) | [
        .task_type, .model, (.n | tostring), ((.error_rate * 100) | round | tostring)
    ] | @tsv
' | awk -F'\t' '{printf "  %-12s  %-12s  %5s  %7s%%\n", $1,$2,$3,$4}'

WARN_N="$(printf '%s' "$WARNINGS" | jq 'length')"
if [[ "$WARN_N" -gt 0 ]]; then
    printf '\n⚠️  BREAK-EVEN BREACH  (haiku/sonnet error rate > 20%% on n >= 5)\n'
    printf '%s\n' "$WARNINGS" | jq -r '
        .[] | "  \(.task_type) on \(.model): error \((.error_rate * 100) | round)%% over \(.n) runs"
    '
    printf '  → Consider raising these task types to the next tier in SKILL.md routing table.\n'
fi

printf '\n'
exit 0

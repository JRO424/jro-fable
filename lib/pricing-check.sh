#!/usr/bin/env bash
# pricing-check.sh — verify that lib/pricing.json still matches claude.com/pricing.
#
# This is a DRIFT DETECTOR, not an auto-updater. It scrapes the pricing page,
# extracts the per-model rates, and compares against lib/pricing.json. If they
# match, it stamps `last_verified` to today. If they drift, it prints the diff
# and exits 1 — humans verify and update pricing.json manually.
#
# Why not auto-update? Scraping is fragile, and silently rewriting cost data
# the entire skill depends on is the kind of "helpful" that breaks routing
# decisions. Drift detection + human verification is the right contract.
#
# Usage:
#   ./pricing-check.sh              # compare against live, report
#   ./pricing-check.sh --stamp      # if no drift, bump last_verified to today
#   ./pricing-check.sh --json       # output machine-readable diff

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRICING_FILE="${SCRIPT_DIR}/pricing.json"
# Try multiple sources. The marketing page is JS-rendered so curl gets a
# shell with no prices; the docs/platform page tends to render server-side.
PRICING_URLS=(
    "${PRICING_URL:-}"
    "https://docs.claude.com/en/docs/about-claude/pricing"
    "https://platform.claude.com/docs/en/about-claude/pricing"
    "https://claude.com/pricing"
)

STAMP_MODE=0
JSON_MODE=0
for arg in "$@"; do
    case "$arg" in
        --stamp) STAMP_MODE=1 ;;
        --json)  JSON_MODE=1 ;;
        --help)  sed -n '2,17p' "$0"; exit 0 ;;
    esac
done

if [[ ! -f "$PRICING_FILE" ]]; then
    printf 'pricing-check: %s not found\n' "$PRICING_FILE" >&2
    exit 2
fi

# Try each URL until one returns something useful (contains a dollar sign)
LIVE_HTML=""
PRICING_URL_USED=""
for u in "${PRICING_URLS[@]}"; do
    [[ -z "$u" ]] && continue
    body="$(curl -fsSL --max-time 12 -A 'Mozilla/5.0 (jro-fable-pricing-check)' "$u" 2>/dev/null || true)"
    if [[ -n "$body" ]] && printf '%s' "$body" | grep -q '\$'; then
        LIVE_HTML="$body"
        PRICING_URL_USED="$u"
        break
    fi
done

if [[ -z "$LIVE_HTML" ]]; then
    printf 'pricing-check: could not reach any pricing source.\n' >&2
    printf '  Tried: %s\n' "${PRICING_URLS[*]}" >&2
    printf '  Cached pricing.json last verified: %s\n' \
        "$(jq -r .last_verified "$PRICING_FILE")" >&2
    exit 3
fi

# Extract dollar amounts that look like Anthropic pricing.
# We don't try to parse the HTML structure — we look for patterns like
# "$10/MTok" or "Input: $10" or "$10.00 / million" near the model names.
# This is fragile by design — drift triggers manual review.
extract_prices() {
    local model_name="$1"
    # Find the section mentioning this model, grab a window of following chars,
    # then pull all dollar amounts. BSD grep caps bounded reps at 255 (an old
    # POSIX limit), so we do the windowing with awk + substr instead.
    printf '%s' "$LIVE_HTML" \
        | tr -d '\n' \
        | awk -v m="$model_name" 'BEGIN{IGNORECASE=1}
            {
              p = index(tolower($0), tolower(m))
              if (p > 0) print substr($0, p, 1500)
            }' \
        | head -1 \
        | grep -oE '\$[0-9]+(\.[0-9]+)?' \
        | head -10 \
        | tr '\n' ' '
}

# Map our pricing.json model IDs to the names likely to appear on the page
declare -a CHECKS=(
    "claude-fable-5|Fable 5|Claude Fable 5|Fable|claude-fable-5"
    "claude-opus-4-8|Opus 4.8|Claude Opus 4.8|Opus|claude-opus-4-8"
    "claude-sonnet-4-6|Sonnet 4.6|Claude Sonnet 4.6|Sonnet|claude-sonnet-4-6"
    "claude-haiku-4-5-20251001|Haiku 4.5|Claude Haiku 4.5|Haiku|claude-haiku-4-5"
)

drift_found=0
unknown_count=0
report_rows=()

for entry in "${CHECKS[@]}"; do
    model_id="${entry%%|*}"
    rest="${entry#*|}"
    primary_display="${rest%%|*}"

    cached_in="$(jq -r --arg m "$model_id"  '.models[$m].input_per_mtok_usd'  "$PRICING_FILE")"
    cached_out="$(jq -r --arg m "$model_id" '.models[$m].output_per_mtok_usd' "$PRICING_FILE")"

    # Try primary display, then fallback labels if any
    live_prices="$(extract_prices "$primary_display")"
    if [[ -z "$live_prices" && "$rest" == *"|"* ]]; then
        IFS='|' read -ra all_displays <<< "$rest"
        for d in "${all_displays[@]:1}"; do
            live_prices="$(extract_prices "$d")"
            [[ -n "$live_prices" ]] && break
        done
    fi

    if [[ -z "$live_prices" ]]; then
        report_rows+=("$primary_display|\$${cached_in}/\$${cached_out}|UNKNOWN (model name not found on page)")
        unknown_count=$((unknown_count + 1))
        continue
    fi

    # Allow either "$3" or "$3.00" form on the live page — many pages drop
    # trailing zeros. Strip ".00" from cached for the regex.
    cached_in_int="${cached_in%.00}"
    cached_out_int="${cached_out%.00}"
    if printf '%s' "$live_prices" | grep -qE "\\\$${cached_in_int}(\.00)?([^0-9.]|\$)" \
       && printf '%s' "$live_prices" | grep -qE "\\\$${cached_out_int}(\.00)?([^0-9.]|\$)"; then
        report_rows+=("$primary_display|\$${cached_in}/\$${cached_out}|MATCH (live had: $live_prices)")
    else
        report_rows+=("$primary_display|\$${cached_in}/\$${cached_out}|DRIFT? live: $live_prices")
        drift_found=1
    fi
done

if [[ "$JSON_MODE" == "1" ]]; then
    jq -nc \
        --arg url "$PRICING_URL" \
        --arg drift "$drift_found" \
        --arg cached_verified "$(jq -r .last_verified "$PRICING_FILE")" \
        --argjson rows "$(printf '%s\n' "${report_rows[@]}" | jq -R 'split("|") | {model:.[0], cached:.[1], live:.[2]}' | jq -s .)" \
        '{url:$url, drift_detected:($drift=="1"), cached_last_verified:$cached_verified, rows:$rows}'
    exit "$drift_found"
fi

printf '\nClaude pricing drift check — %s\n' "$(date '+%Y-%m-%d %H:%M')"
printf 'Cached pricing.json last verified: %s\n' "$(jq -r .last_verified "$PRICING_FILE")"
printf 'Live source used: %s\n\n' "$PRICING_URL_USED"

printf '  %-18s  %-22s  %s\n' "MODEL" "CACHED (in/out)" "LIVE"
printf '  %-18s  %-22s  %s\n' "-----" "---------------" "----"
for row in "${report_rows[@]}"; do
    IFS='|' read -r m c l <<< "$row"
    printf '  %-18s  %-22s  %s\n' "$m" "$c" "$l"
done
printf '\n'

if [[ "$drift_found" == "1" ]]; then
    printf '⚠️  DRIFT DETECTED. Verify pricing on the live page, then edit pricing.json manually.\n\n'
    exit 1
fi
if [[ "$unknown_count" -gt 0 ]]; then
    printf '? %d model(s) not found on the live page — page structure may have changed.\n' "$unknown_count"
    printf '  Visit %s manually and verify, then run with --stamp.\n\n' "$PRICING_URL_USED"
    exit 4
fi

printf '✓ All four models match cached pricing.\n'
if [[ "$STAMP_MODE" == "1" ]]; then
    tmp="$(mktemp)"
    today="$(date '+%Y-%m-%d')"
    jq --arg d "$today" '.last_verified = $d' "$PRICING_FILE" > "$tmp" && mv "$tmp" "$PRICING_FILE"
    printf '  last_verified stamped to %s\n' "$today"
fi
printf '\n'
exit 0

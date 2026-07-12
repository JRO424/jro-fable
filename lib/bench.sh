#!/bin/bash
# bench.sh — JRO-Fable model benchmark harness
# Measures latency, output size, and (optionally) quality across task types.
# Requires: jq, gdate (brew install coreutils). bash 3.2 compatible (macOS system bash).
# Usage: ./bench.sh --help
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (relative to this script, which lives in lib/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TASKS_DIR="${SKILL_DIR}/benchmarks/tasks"
RESULTS_DIR="${SKILL_DIR}/benchmarks/results"
PRICING_JSON="${SCRIPT_DIR}/pricing.json"
CLAUDE_BIN="${CLAUDE_BIN:-/opt/homebrew/bin/claude}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# Apex (judge + baseline) model — read the LIVE binding from pricing.json. Fable 5 is unavailable,
# so this resolves to Opus 4.8. Re-point by editing lib/pricing.json -> tiers.judgment.current.
APEX_MODEL="$(jq -r '.tiers.judgment.current // "claude-opus-4-8"' "${PRICING_JSON}" 2>/dev/null || echo claude-opus-4-8)"
# Default model set = available models only (Fable 5 excluded). Apex is included via Opus 4.8.
ALL_MODELS="claude-haiku-4-5-20251001,claude-sonnet-4-6,claude-opus-4-8"
OPT_TASKS_GLOB="*.txt"
OPT_MODELS="${ALL_MODELS}"
OPT_RUNS=1
OPT_JUDGE=0
OPT_DRY_RUN=0

# ---------------------------------------------------------------------------
# Pricing — hardcoded fallbacks ($ per MTok input / output)
# Format: <model>:<price_in>:<price_out>  stored in a plain string list
# ---------------------------------------------------------------------------
PRICING_TABLE="claude-fable-5:10:50 claude-opus-4-8:5:25 claude-sonnet-4-6:3:15 claude-haiku-4-5-20251001:1:5"

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
bench.sh — JRO-Fable model benchmark harness

USAGE
  bench.sh [OPTIONS]

OPTIONS
  --tasks <glob>    Only run task files matching glob (default: *.txt)
                    Example: --tasks "summarize-*.txt"
  --models <csv>    Comma-separated model IDs to test (default: all four)
                    Example: --models "claude-haiku-4-5-20251001,claude-sonnet-4-6"
  --runs <n>        Repeat each (task × model) N times to reduce variance (default: 1)
  --judge           After main runs, use the apex model (pricing.json tiers.judgment.current,
                    currently Opus 4.8) to score each other response 1–10 vs the apex baseline.
  --dry-run         Print what would run, then exit (no API calls)
  --help            Show this message

MODELS (default — available only; apex = Opus 4.8, Fable 5 unavailable)
  claude-haiku-4-5-20251001
  claude-sonnet-4-6
  claude-opus-4-8

TASK FILE FORMAT
  Line 1:  task_id: <slug>
  Line 2:  task_type: <search|summarize|extract|edit|decompose|refactor|judge|review>
  Line 3:  expected_shape: <free text — what good output looks like>
  Line 4:  (blank)
  Lines 5+: the prompt text

OUTPUT
  benchmarks/results/<RUN_ID>/raw.jsonl          — one JSON row per (task × model × run)
  benchmarks/results/<RUN_ID>/<task>__<model>.txt — full response text
  benchmarks/results/<RUN_ID>/summary.md          — markdown table: latency, chars, cost

AUTH NOTE
  --bare mode requires ANTHROPIC_API_KEY (keychain/OAuth are skipped in bare mode).
  If ANTHROPIC_API_KEY is unset, bench.sh falls back to standard mode (no --bare),
  which uses your OAuth session but includes hooks and auto-memory overhead.
  Set ANTHROPIC_API_KEY for clean isolated measurements.

EXAMPLES
  bench.sh --dry-run
  bench.sh --tasks "summarize-*.txt" --models "claude-haiku-4-5-20251001,claude-sonnet-4-6"
  bench.sh --runs 3 --judge
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --tasks)   OPT_TASKS_GLOB="$2"; shift 2 ;;
    --models)  OPT_MODELS="$2";     shift 2 ;;
    --runs)    OPT_RUNS="$2";       shift 2 ;;
    --judge)   OPT_JUDGE=1;         shift   ;;
    --dry-run) OPT_DRY_RUN=1;       shift   ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate dependencies
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq not found. Install with: brew install jq\n' >&2; exit 1
fi
if ! command -v gdate >/dev/null 2>&1; then
  printf 'ERROR: gdate not found. Install with: brew install coreutils\n' >&2; exit 1
fi
if [ ! -x "${CLAUDE_BIN}" ]; then
  printf 'ERROR: claude CLI not found at %s. Set CLAUDE_BIN to override.\n' "${CLAUDE_BIN}" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Determine --bare flag availability
# ---------------------------------------------------------------------------
BARE_FLAG=""
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  BARE_FLAG="--bare"
else
  printf 'WARN: ANTHROPIC_API_KEY not set — running without --bare (OAuth mode).\n' >&2
  printf '      Measurements include hook/auto-memory overhead. Set ANTHROPIC_API_KEY for isolation.\n' >&2
fi

# ---------------------------------------------------------------------------
# Pricing helpers (bash 3.2 compatible — no associative arrays)
# get_price_in <model>  → input $/MTok
# get_price_out <model> → output $/MTok
# ---------------------------------------------------------------------------
get_price_in() {
  local model="$1"
  # Try pricing.json first
  if [ -f "${PRICING_JSON}" ]; then
    local v
    v=$(jq -r --arg m "${model}" '.models[$m].input // empty' "${PRICING_JSON}" 2>/dev/null)
    [ -n "${v}" ] && { printf '%s' "${v}"; return; }
  fi
  # Fallback hardcoded table
  local entry
  for entry in ${PRICING_TABLE}; do
    local m="${entry%%:*}"
    if [ "${m}" = "${model}" ]; then
      local rest="${entry#*:}"
      printf '%s' "${rest%%:*}"
      return
    fi
  done
  printf '0'
}

get_price_out() {
  local model="$1"
  if [ -f "${PRICING_JSON}" ]; then
    local v
    v=$(jq -r --arg m "${model}" '.models[$m].output // empty' "${PRICING_JSON}" 2>/dev/null)
    [ -n "${v}" ] && { printf '%s' "${v}"; return; }
  fi
  local entry
  for entry in ${PRICING_TABLE}; do
    local m="${entry%%:*}"
    if [ "${m}" = "${model}" ]; then
      local rest="${entry#*:}"
      printf '%s' "${rest##*:}"
      return
    fi
  done
  printf '0'
}

# ---------------------------------------------------------------------------
# Cost estimate: cost_estimate <model> <in_chars> <out_chars> → USD string
# ---------------------------------------------------------------------------
cost_estimate() {
  local model="$1" in_chars="$2" out_chars="$3"
  local p_in p_out
  p_in=$(get_price_in "${model}")
  p_out=$(get_price_out "${model}")
  python3 -c "
in_t=${in_chars}/4.0; out_t=${out_chars}/4.0
cost=(in_t/1e6)*${p_in} + (out_t/1e6)*${p_out}
print(f'{cost:.6f}')
" 2>/dev/null || printf '0.000000'
}

# ---------------------------------------------------------------------------
# Short model alias for column headers
# ---------------------------------------------------------------------------
model_short() {
  case "$1" in
    claude-fable-5)            printf 'fable' ;;
    claude-opus-4-8)           printf 'opus' ;;
    claude-sonnet-4-6)         printf 'sonnet' ;;
    claude-haiku-4-5-20251001) printf 'haiku' ;;
    *)                         printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Collect task files into a newline-separated list (bash 3.2 safe)
# ---------------------------------------------------------------------------
collect_task_files() {
  find "${TASKS_DIR}" -maxdepth 1 -name "${OPT_TASKS_GLOB}" 2>/dev/null | sort
}

TASK_FILES_LIST="$(collect_task_files)"
if [ -z "${TASK_FILES_LIST}" ]; then
  printf 'ERROR: No task files found in %s matching %s\n' "${TASKS_DIR}" "${OPT_TASKS_GLOB}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse models into space-separated list
# ---------------------------------------------------------------------------
MODELS_LIST="$(printf '%s' "${OPT_MODELS}" | tr ',' ' ')"

# ---------------------------------------------------------------------------
# Dry-run: show plan and exit
# ---------------------------------------------------------------------------
if [ "${OPT_DRY_RUN}" -eq 1 ]; then
  printf '=== DRY RUN ===\n'
  printf 'Tasks dir  : %s\n' "${TASKS_DIR}"
  printf 'Results dir: %s/<RUN_ID>/\n' "${RESULTS_DIR}"
  printf 'Runs each  : %s\n' "${OPT_RUNS}"
  if [ "${OPT_JUDGE}" -eq 1 ]; then
    printf 'Judge pass : yes\n'
  else
    printf 'Judge pass : no\n'
  fi
  if [ -n "${BARE_FLAG}" ]; then
    printf 'Bare flag  : --bare\n'
  else
    printf 'Bare flag  : (none — OAuth fallback)\n'
  fi
  printf '\nWould execute:\n'

  total=0
  while IFS= read -r task_file; do
    [ -z "${task_file}" ] && continue
    task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
    task_type=$(sed -n '2s/^task_type:[[:space:]]*//p' "${task_file}")
    for model in ${MODELS_LIST}; do
      run=1
      while [ "${run}" -le "${OPT_RUNS}" ]; do
        printf '  [run %s/%s] %s (%s) x %s\n' "${run}" "${OPT_RUNS}" "${task_id}" "${task_type}" "${model}"
        printf '    %s -p '"'"'<prompt>'"'"' --model %s %s\n' "${CLAUDE_BIN}" "${model}" "${BARE_FLAG}"
        total=$(( total + 1 ))
        run=$(( run + 1 ))
      done
    done
  done <<EOF
${TASK_FILES_LIST}
EOF

  if [ "${OPT_JUDGE}" -eq 1 ]; then
    printf '\n  [judge pass] each non-apex response scored 1-10 by %s\n' "${APEX_MODEL}"
  fi
  printf '\nTotal API calls: %s' "${total}"
  if [ "${OPT_JUDGE}" -eq 1 ]; then
    # judge calls = tasks x (models - 1)
    n_tasks=$(printf '%s' "${TASK_FILES_LIST}" | grep -c . || true)
    n_models=$(printf '%s' "${MODELS_LIST}" | wc -w | tr -d ' ')
    judge_calls=$(( n_tasks * (n_models - 1) ))
    printf ' (+ %s judge calls)\n' "${judge_calls}"
  else
    printf '\n'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Setup run directory
# ---------------------------------------------------------------------------
RUN_ID=$(gdate +%Y%m%d-%H%M%S)
RUN_DIR="${RESULTS_DIR}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

JSONL_FILE="${RUN_DIR}/raw.jsonl"
SUMMARY_FILE="${RUN_DIR}/summary.md"
# Temp file to accumulate per-row stats for summary (TSV: task_id|model|latency|chars|cost|error|judge_score|judge_reason)
STATS_TSV="${RUN_DIR}/.stats.tsv"
touch "${STATS_TSV}"

printf 'INFO: Run ID: %s\n' "${RUN_ID}" >&2
printf 'INFO: Results in: %s\n' "${RUN_DIR}" >&2

# ---------------------------------------------------------------------------
# Main benchmark loop
# ---------------------------------------------------------------------------
while IFS= read -r task_file; do
  [ -z "${task_file}" ] && continue

  task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
  task_type=$(sed -n '2s/^task_type:[[:space:]]*//p' "${task_file}")
  expected_shape=$(sed -n '3s/^expected_shape:[[:space:]]*//p' "${task_file}")
  # Prompt starts at line 5 (skip 3 header lines + 1 blank)
  prompt=$(tail -n +5 "${task_file}")

  if [ -z "${task_id}" ]; then
    printf 'WARN: Could not parse task_id from %s, skipping.\n' "${task_file}" >&2
    continue
  fi

  printf '\n--- Task: %s (%s) ---\n' "${task_id}" "${task_type}" >&2

  for model in ${MODELS_LIST}; do
    total_latency=0
    total_out_chars=0
    last_exit=0
    error_msg=""

    run=1
    while [ "${run}" -le "${OPT_RUNS}" ]; do
      printf '  [%s/%s] %s\n' "${run}" "${OPT_RUNS}" "${model}" >&2

      tmp_out=$(mktemp /tmp/bench_out.XXXXXX)
      tmp_err=$(mktemp /tmp/bench_err.XXXXXX)

      t_start=$(gdate +%s%3N)

      set +e
      if [ -n "${BARE_FLAG}" ]; then
        "${CLAUDE_BIN}" -p "${prompt}" --model "${model}" --bare \
          >"${tmp_out}" 2>"${tmp_err}"
      else
        "${CLAUDE_BIN}" -p "${prompt}" --model "${model}" \
          >"${tmp_out}" 2>"${tmp_err}"
      fi
      exit_code=$?
      set -e

      t_end=$(gdate +%s%3N)
      latency_ms=$(( t_end - t_start ))
      response=$(cat "${tmp_out}")
      stderr_out=$(cat "${tmp_err}")

      out_chars="${#response}"
      in_chars="${#prompt}"
      first_500="${response:0:500}"
      ts=$(gdate -u +%Y-%m-%dT%H:%M:%SZ)

      # Write full response to per-task file (last run wins on multi-run)
      model_safe="$(printf '%s' "${model}" | tr '/' '_')"
      response_file="${RUN_DIR}/${task_id}__${model_safe}.txt"
      printf '%s' "${response}" > "${response_file}"

      # Write JSONL row
      jq -n \
        --arg ts "${ts}" \
        --arg run_id "${RUN_ID}" \
        --arg task_id "${task_id}" \
        --arg task_type "${task_type}" \
        --arg model "${model}" \
        --argjson latency_ms "${latency_ms}" \
        --argjson exit_code "${exit_code}" \
        --argjson output_chars "${out_chars}" \
        --arg response_first_500 "${first_500}" \
        --argjson run_num "${run}" \
        '{ts:$ts,run_id:$run_id,task_id:$task_id,task_type:$task_type,
          model:$model,run:$run_num,latency_ms:$latency_ms,exit_code:$exit_code,
          output_chars:$output_chars,response_first_500:$response_first_500}' \
        >> "${JSONL_FILE}"

      if [ "${exit_code}" -ne 0 ]; then
        err_line=$(head -1 "${tmp_err}" 2>/dev/null || true)
        printf '    ERROR: exit %s — %s\n' "${exit_code}" "${err_line}" >&2
        error_msg="exit ${exit_code}: ${err_line}"
      fi

      total_latency=$(( total_latency + latency_ms ))
      total_out_chars=$(( total_out_chars + out_chars ))
      last_exit=${exit_code}

      rm -f "${tmp_out}" "${tmp_err}"
      run=$(( run + 1 ))
    done  # runs

    avg_latency=$(( total_latency / OPT_RUNS ))
    avg_out_chars=$(( total_out_chars / OPT_RUNS ))
    in_chars="${#prompt}"
    cost=$(cost_estimate "${model}" "${in_chars}" "${avg_out_chars}")

    # Append stats row (pipe-delimited for safe parsing)
    printf '%s|%s|%s|%s|%s|%s|||\n' \
      "${task_id}" "${model}" "${avg_latency}" "${avg_out_chars}" "${cost}" "${error_msg}" \
      >> "${STATS_TSV}"

  done  # models
done <<EOF
${TASK_FILES_LIST}
EOF

# ---------------------------------------------------------------------------
# Judge pass (optional)
# ---------------------------------------------------------------------------
if [ "${OPT_JUDGE}" -eq 1 ]; then
  printf '\n--- Judge pass (%s scoring other responses 1-10 vs the apex baseline) ---\n' "${APEX_MODEL}" >&2

  while IFS= read -r task_file; do
    [ -z "${task_file}" ] && continue
    task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
    expected_shape=$(sed -n '3s/^expected_shape:[[:space:]]*//p' "${task_file}")

    # Get the apex baseline response (other models are scored against it)
    base_file="${RUN_DIR}/${task_id}__$(printf '%s' "${APEX_MODEL}" | tr '/' '_').txt"
    if [ ! -f "${base_file}" ]; then
      printf '  SKIP judge for %s: no apex (%s) baseline response\n' "${task_id}" "${APEX_MODEL}" >&2
      continue
    fi
    base_response=$(cat "${base_file}")

    for model in ${MODELS_LIST}; do
      [ "${model}" = "${APEX_MODEL}" ] && continue

      model_safe="$(printf '%s' "${model}" | tr '/' '_')"
      candidate_file="${RUN_DIR}/${task_id}__${model_safe}.txt"
      [ ! -f "${candidate_file}" ] && continue

      candidate_response=$(cat "${candidate_file}")

      judge_prompt="You are a precise evaluator. Score the CANDIDATE response 1-10 compared to the REFERENCE response.

TASK EXPECTED SHAPE: ${expected_shape}

REFERENCE (${APEX_MODEL}):
${base_response:0:2000}

CANDIDATE (${model}):
${candidate_response:0:2000}

Reply with ONLY this format (no prose):
SCORE: <1-10>
REASON: <one sentence>"

      printf '  Judging %s x %s\n' "${task_id}" "${model}" >&2
      tmp_judge=$(mktemp /tmp/bench_judge.XXXXXX)

      set +e
      if [ -n "${BARE_FLAG}" ]; then
        "${CLAUDE_BIN}" -p "${judge_prompt}" --model "${APEX_MODEL}" --bare \
          >"${tmp_judge}" 2>/dev/null
      else
        "${CLAUDE_BIN}" -p "${judge_prompt}" --model "${APEX_MODEL}" \
          >"${tmp_judge}" 2>/dev/null
      fi
      set -e

      judge_output=$(cat "${tmp_judge}")
      score=$(printf '%s' "${judge_output}" | grep '^SCORE:' | sed 's/SCORE:[[:space:]]*//' | head -1)
      reason=$(printf '%s' "${judge_output}" | grep '^REASON:' | sed 's/REASON:[[:space:]]*//' | head -1)
      score="${score:-?}"

      # Append judge JSONL row
      jq -n \
        --arg run_id "${RUN_ID}" \
        --arg task_id "${task_id}" \
        --arg model "${model}" \
        --arg score "${score}" \
        --arg reason "${reason:-}" \
        '{run_id:$run_id,task_id:$task_id,model:$model,judge:true,
          judge_score:$score,judge_reason:$reason}' \
        >> "${JSONL_FILE}"

      # Update stats TSV: append a judge-only row (task|model|||||score|reason)
      printf '%s|%s||||judge|%s|%s\n' \
        "${task_id}" "${model}" "${score}" "${reason:-}" \
        >> "${STATS_TSV}"

      rm -f "${tmp_judge}"
    done
  done <<EOF2
${TASK_FILES_LIST}
EOF2
fi

# ---------------------------------------------------------------------------
# Write summary.md
# ---------------------------------------------------------------------------
{
  printf '# Benchmark Summary — Run %s\n\n' "${RUN_ID}"
  printf '- Tasks dir: `%s`\n' "${TASKS_DIR}"
  printf '- Task glob: `%s`\n' "${OPT_TASKS_GLOB}"
  printf '- Models: %s\n' "${OPT_MODELS}"
  printf '- Runs per (task x model): %s\n' "${OPT_RUNS}"
  if [ -n "${BARE_FLAG}" ]; then
    printf '- Bare mode: yes (ANTHROPIC_API_KEY set)\n'
  else
    printf '- Bare mode: no (OAuth fallback — overhead included in measurements)\n'
  fi
  if [ "${OPT_JUDGE}" -eq 1 ]; then
    printf '- Judge pass: yes\n'
  else
    printf '- Judge pass: no\n'
  fi
  printf '\n'

  # ----- Latency + output size table -----
  printf '## Latency & Output (averages over %s run(s))\n\n' "${OPT_RUNS}"

  # Build header
  header="| task_id | task_type"
  sep="| --- | ---"
  for model in ${MODELS_LIST}; do
    short=$(model_short "${model}")
    header="${header} | ${short} ms | ${short} chars"
    sep="${sep} | --- | ---"
  done
  printf '%s |\n' "${header}"
  printf '%s |\n' "${sep}"

  while IFS= read -r task_file; do
    [ -z "${task_file}" ] && continue
    task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
    task_type=$(sed -n '2s/^task_type:[[:space:]]*//p' "${task_file}")
    row="| ${task_id} | ${task_type}"
    for model in ${MODELS_LIST}; do
      # Look up stats from TSV (main run rows have 8 pipe fields, field 6 = error)
      stats_line=$(grep "^${task_id}|${model}|" "${STATS_TSV}" | grep -v '^.*|.*|.*|.*|.*|judge|' | head -1 || true)
      if [ -n "${stats_line}" ]; then
        lat=$(printf '%s' "${stats_line}" | cut -d'|' -f3)
        chars=$(printf '%s' "${stats_line}" | cut -d'|' -f4)
        err=$(printf '%s' "${stats_line}" | cut -d'|' -f6)
        if [ -n "${err}" ]; then
          row="${row} | ERR | ERR"
        else
          row="${row} | ${lat} | ${chars}"
        fi
      else
        row="${row} | — | —"
      fi
    done
    printf '%s |\n' "${row}"
  done <<EOF
${TASK_FILES_LIST}
EOF

  printf '\n'

  # ----- Cost table -----
  printf '## Estimated Cost (USD, input+output at current pricing)\n\n'
  # Build pricing note
  price_note=""
  for entry in ${PRICING_TABLE}; do
    m="${entry%%:*}"
    rest="${entry#*:}"
    p_in="${rest%%:*}"
    p_out="${rest##*:}"
    price_note="${price_note} ${m}(in=\$${p_in} out=\$${p_out}/MTok);"
  done
  printf '_Pricing:%s_\n' "${price_note}"
  printf '_Token estimate: chars/4 (rough proxy)_\n\n'

  cost_header="| task_id | task_type"
  cost_sep="| --- | ---"
  for model in ${MODELS_LIST}; do
    short=$(model_short "${model}")
    cost_header="${cost_header} | ${short} \$"
    cost_sep="${cost_sep} | ---"
  done
  printf '%s |\n' "${cost_header}"
  printf '%s |\n' "${cost_sep}"

  while IFS= read -r task_file; do
    [ -z "${task_file}" ] && continue
    task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
    task_type=$(sed -n '2s/^task_type:[[:space:]]*//p' "${task_file}")
    row="| ${task_id} | ${task_type}"
    for model in ${MODELS_LIST}; do
      stats_line=$(grep "^${task_id}|${model}|" "${STATS_TSV}" | grep -v '^.*|.*|.*|.*|.*|judge|' | head -1 || true)
      if [ -n "${stats_line}" ]; then
        cost=$(printf '%s' "${stats_line}" | cut -d'|' -f5)
        err=$(printf '%s' "${stats_line}" | cut -d'|' -f6)
        if [ -n "${err}" ]; then
          row="${row} | ERR"
        else
          row="${row} | \$${cost}"
        fi
      else
        row="${row} | —"
      fi
    done
    printf '%s |\n' "${row}"
  done <<EOF
${TASK_FILES_LIST}
EOF

  printf '\n'

  # ----- Judge scores (if applicable) -----
  if [ "${OPT_JUDGE}" -eq 1 ]; then
    printf '## Judge Scores (1–10 vs %s baseline)\n\n' "${APEX_MODEL}"
    judge_header="| task_id | task_type"
    judge_sep="| --- | ---"
    for model in ${MODELS_LIST}; do
      [ "${model}" = "${APEX_MODEL}" ] && continue
      short=$(model_short "${model}")
      judge_header="${judge_header} | ${short} score | ${short} reason"
      judge_sep="${judge_sep} | --- | ---"
    done
    printf '%s |\n' "${judge_header}"
    printf '%s |\n' "${judge_sep}"

    while IFS= read -r task_file; do
      [ -z "${task_file}" ] && continue
      task_id=$(sed -n '1s/^task_id:[[:space:]]*//p' "${task_file}")
      task_type=$(sed -n '2s/^task_type:[[:space:]]*//p' "${task_file}")
      row="| ${task_id} | ${task_type}"
      for model in ${MODELS_LIST}; do
        [ "${model}" = "${APEX_MODEL}" ] && continue
        judge_line=$(grep "^${task_id}|${model}|.*|judge|" "${STATS_TSV}" | head -1 || true)
        if [ -n "${judge_line}" ]; then
          score=$(printf '%s' "${judge_line}" | cut -d'|' -f7)
          reason=$(printf '%s' "${judge_line}" | cut -d'|' -f8)
          row="${row} | ${score} | ${reason}"
        else
          row="${row} | — | —"
        fi
      done
      printf '%s |\n' "${row}"
    done <<EOF
${TASK_FILES_LIST}
EOF
    printf '\n'
  fi

  # ----- Errors -----
  printf '## Errors\n\n'
  has_errors=0
  while IFS='|' read -r t_id t_model _lat _chars _cost t_err _js _jr; do
    [ -z "${t_err}" ] && continue
    [ "${t_err}" = "judge" ] && continue
    printf '- **%s** x `%s`: %s\n' "${t_id}" "${t_model}" "${t_err}"
    has_errors=1
  done < "${STATS_TSV}"
  [ "${has_errors}" -eq 0 ] && printf '_No errors._\n'
  printf '\n'

  printf '---\n'
  printf '_Generated by bench.sh at %s_\n' "$(gdate -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '_Raw data: `%s`_\n' "${JSONL_FILE}"

} > "${SUMMARY_FILE}"

# Cleanup temp stats file
rm -f "${STATS_TSV}"

printf '\n=== Done ===\n' >&2
printf 'Run ID  : %s\n' "${RUN_ID}" >&2
printf 'JSONL   : %s\n' "${JSONL_FILE}" >&2
printf 'Summary : %s\n' "${SUMMARY_FILE}" >&2

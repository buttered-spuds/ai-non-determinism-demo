#!/usr/bin/env bash
# orchestrate-single-agent.sh -- Single parent-agent UI review orchestrator
# Replicates orchestrate.sh but collapses the three copilot calls per screenshot
# (Agent A, Agent B, consensus) into ONE call to a parent agent.
# The parent agent is prompted to produce two independent reviewer perspectives
# and a consensus synthesis in a single structured response, which is then split
# into the same three artifact files as orchestrate.sh.
#
# Trade-off vs orchestrate.sh:
#   + ~66% fewer API calls (1 call per screenshot vs 3)
#   - Both reviewer perspectives come from the same model in the same context
#     window, losing the cross-model diversity of Claude vs GPT
#
# Prerequisites:
#   - copilot CLI installed and authenticated (github.com/github/copilot-cli)
#   - npx / Node.js available
#
# No API keys required -- all model calls are routed through the copilot CLI.

set -euo pipefail
shopt -s nullglob
SCRIPT_START=$SECONDS

STEP_START=$SECONDS

# Call counters
SUCCESSFUL_CALLS=0
FAILED_CALLS=0

elapsed() {
  local step_secs=$(( SECONDS - STEP_START ))
  local total_secs=$(( SECONDS - SCRIPT_START ))
  echo "    (step: ${step_secs}s | total: ${total_secs}s)"
  STEP_START=$SECONDS
}

prepend_nav() {
  local file="$1"
  local nav="$2"
  local tmp
  tmp=$(mktemp)
  { echo -e "$nav\n\n---\n"; cat "$file"; } > "$tmp" && mv "$tmp" "$file"
}

# extract_section <start_marker> <end_marker> <file>
# Prints lines between start_marker and end_marker (exclusive).
# If end_marker is empty, captures from start_marker to EOF.
extract_section() {
  local start="$1"
  local end="$2"
  local file="$3"
  awk -v start="$start" -v end="$end" '
    index($0, start) > 0              { capture=1; next }
    end != "" && index($0, end) > 0   { capture=0; next }
    capture                           { print }
  ' "$file"
}

# -----------------------------------------------------------------------------
# call_copilot -- timeout + exponential-backoff retry wrapper
# -----------------------------------------------------------------------------
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  echo "WARNING: No 'timeout' command found (install 'coreutils' via Homebrew). Calls will not be time-bounded." >&2
  TIMEOUT_CMD=""
fi

# Longer default than orchestrate.sh -- the parent agent does ~3x the work.
COPILOT_TIMEOUT=${COPILOT_TIMEOUT:-180}
COPILOT_RETRIES=${COPILOT_RETRIES:-3}

# call_copilot <model> <prompt>
# Prints model output to stdout on success; returns 1 after all retries exhausted.
call_copilot() {
  local model="$1"
  local prompt="$2"
  local attempt delay output rc
  delay=5
  for (( attempt=1; attempt<=COPILOT_RETRIES; attempt++ )); do
    if [[ -n "$TIMEOUT_CMD" ]]; then
      output=$("$TIMEOUT_CMD" "$COPILOT_TIMEOUT" copilot --model "$model" -s -p "$prompt" 2>&1)
    else
      output=$(copilot --model "$model" -s -p "$prompt" 2>&1)
    fi
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$output"
      return 0
    fi
    if [[ $rc -eq 124 ]]; then
      echo "    WARNING: copilot timed out after ${COPILOT_TIMEOUT}s (attempt ${attempt}/${COPILOT_RETRIES}, model=${model})" >&2
    else
      echo "    WARNING: copilot exited ${rc} (attempt ${attempt}/${COPILOT_RETRIES}, model=${model})" >&2
    fi
    if (( attempt < COPILOT_RETRIES )); then
      echo "    Retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$(( delay * 3 ))
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------
if ! command -v copilot &>/dev/null; then
  echo "ERROR: 'copilot' CLI not found. Install it and authenticate first." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Setup -- read and validate MIN_SEVERITY
# -----------------------------------------------------------------------------
MIN_SEVERITY=$(grep -E '^MIN_SEVERITY=' "$SCRIPTS_DIR/config/settings.txt" 2>/dev/null \
  | cut -d'=' -f2 \
  | tr -d '[:space:]') || true

case "$MIN_SEVERITY" in
  S1|S2|S3|S4) ;;
  *)
    echo "WARNING: Invalid MIN_SEVERITY value '${MIN_SEVERITY}'. Defaulting to S3." >&2
    MIN_SEVERITY="S3"
    ;;
esac

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARTIFACTS_DIR="$REPO_ROOT/artifacts/run-${TIMESTAMP}"
mkdir -p "$ARTIFACTS_DIR"

echo "==> Artifacts will be written to: $ARTIFACTS_DIR"
echo "==> MIN_SEVERITY: $MIN_SEVERITY"
echo "==> Mode: single parent-agent (1 call per screenshot)"

# -----------------------------------------------------------------------------
# Step 1 -- Run Playwright
# -----------------------------------------------------------------------------
echo ""
echo "==> Step 1: Running Playwright tests..."
cd "$REPO_ROOT"
if ! npx playwright test; then
  echo "ERROR: Playwright tests failed. Aborting." >&2
  exit 1
fi
elapsed

# -----------------------------------------------------------------------------
# Step 2 -- Build ignore list
# -----------------------------------------------------------------------------
IGNORE_FILE="$SCRIPTS_DIR/config/ignore.txt"
IGNORE_ENTRIES=""
if [[ -f "$IGNORE_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    IGNORE_ENTRIES+="- ${line}"$'\n'
  done < "$IGNORE_FILE"
fi

IGNORE_BLOCK=""
if [[ -n "$IGNORE_ENTRIES" ]]; then
  IGNORE_BLOCK=$'The following issues have been marked as accepted/wontfix. Do NOT raise or mention these:\n'"$IGNORE_ENTRIES"
fi

# -----------------------------------------------------------------------------
# Step 3 -- Review each screenshot
# -----------------------------------------------------------------------------
REVIEWER_TEMPLATE=$(cat "$SCRIPTS_DIR/prompts/reviewer.txt")
CONSENSUS_TEMPLATE=$(cat "$SCRIPTS_DIR/prompts/consensus.txt")
CONTEXT_FILE="$SCRIPTS_DIR/config/context.txt"

SUMMARY_SECTIONS=()

# Section markers -- must match exactly what the parent agent is prompted to output.
MARKER_A="=== AGENT A REVIEW ==="
MARKER_B="=== AGENT B REVIEW ==="
MARKER_C="=== CONSENSUS ==="
MARKER_END="=== END ==="

SCREENSHOTS=("$REPO_ROOT/tests/screenshots/"*.png)
if [[ ${#SCREENSHOTS[@]} -eq 0 ]]; then
  echo "ERROR: No screenshots found in $REPO_ROOT/tests/screenshots/." >&2
  echo "Run the Playwright tests and ensure screenshots are generated before retrying." >&2
  exit 1
fi

for screenshot in "${SCREENSHOTS[@]}"; do

  if [[ "$screenshot" == *" "* ]]; then
    echo "ERROR: Screenshot path contains spaces: $screenshot" >&2
    echo "Move the repository to a space-free path and retry." >&2
    exit 1
  fi

  basename_ext="${screenshot##*/}"
  basename="${basename_ext%.png}"

  echo ""
  echo "==> Processing: $basename"

  # Look up description from context.txt
  description=""
  if [[ -f "$CONTEXT_FILE" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      key="${line%%=*}"
      if [[ "$key" == "$basename" ]]; then
        description="${line#*=}"
        break
      fi
    done < "$CONTEXT_FILE"
  fi
  [[ -z "$description" ]] && description="$basename"

  # ---------------------------------------------------------------------------
  # Build the single parent-agent prompt.
  #
  # The model is instructed to output content for AGENT A, AGENT B, and
  # CONSENSUS separated by exact marker lines. The raw output is written to a
  # temp file so awk can parse it into three separate artifact files.
  # ---------------------------------------------------------------------------
  PARENT_PROMPT="@${screenshot} This screenshot shows: ${description}"$'\n\n'
  PARENT_PROMPT+="You are an AI orchestrating agent. Review this screenshot by producing output in EXACTLY this four-section structure. Each === marker must appear verbatim on its own line with no surrounding text. Begin your response with the first marker."$'\n\n'
  PARENT_PROMPT+="OUTPUT FORMAT"$'\n'
  PARENT_PROMPT+="-------------"$'\n'
  PARENT_PROMPT+="${MARKER_A}"$'\n'
  PARENT_PROMPT+="(Agent A review here)"$'\n'
  PARENT_PROMPT+="${MARKER_B}"$'\n'
  PARENT_PROMPT+="(Agent B review here)"$'\n'
  PARENT_PROMPT+="${MARKER_C}"$'\n'
  PARENT_PROMPT+="(Consensus here)"$'\n'
  PARENT_PROMPT+="${MARKER_END}"$'\n\n'
  PARENT_PROMPT+="REVIEWER GUIDELINES (apply to both Agent A and Agent B)"$'\n'
  PARENT_PROMPT+="-------------------------------------------------------"$'\n'
  PARENT_PROMPT+="${REVIEWER_TEMPLATE}"$'\n\n'
  PARENT_PROMPT+="Agent A -- focus on TECHNICAL CORRECTNESS and ACCESSIBILITY."$'\n'
  PARENT_PROMPT+="Agent B -- focus on END-USER EXPERIENCE and USABILITY. Write Agent B as if you have NOT seen Agent A's review."$'\n\n'
  PARENT_PROMPT+="CONSENSUS GUIDELINES"$'\n'
  PARENT_PROMPT+="--------------------"$'\n'
  PARENT_PROMPT+="${CONSENSUS_TEMPLATE}"$'\n'
  PARENT_PROMPT+="MIN_SEVERITY: ${MIN_SEVERITY}"$'\n'
  if [[ -n "$IGNORE_BLOCK" ]]; then
    PARENT_PROMPT+=$'\n'"${IGNORE_BLOCK}"
  fi

  RAW_OUTPUT_FILE="$ARTIFACTS_DIR/${basename}-raw.txt"

  echo "    -> Calling parent agent (claude-sonnet-4.6)..."
  if ! call_copilot "claude-sonnet-4.6" "$PARENT_PROMPT" > "$RAW_OUTPUT_FILE"; then
    (( ++FAILED_CALLS ))
    echo "    ✗ Parent agent FAILED for $basename" >&2
    for suffix in agent-a agent-b consensus; do
      echo "FAILED" > "$ARTIFACTS_DIR/${basename}-${suffix}.md"
    done
    SUMMARY_SECTIONS+=("$basename")
    elapsed
    continue
  fi
  (( ++SUCCESSFUL_CALLS ))
  echo "    ✓ Parent agent done"

  # Parse each section out of the raw output
  extract_section "$MARKER_A" "$MARKER_B"   "$RAW_OUTPUT_FILE" > "$ARTIFACTS_DIR/${basename}-agent-a.md"
  extract_section "$MARKER_B" "$MARKER_C"   "$RAW_OUTPUT_FILE" > "$ARTIFACTS_DIR/${basename}-agent-b.md"
  extract_section "$MARKER_C" "$MARKER_END" "$RAW_OUTPUT_FILE" > "$ARTIFACTS_DIR/${basename}-consensus.md"

  # Add navigation headers (identical format to orchestrate.sh)
  prepend_nav "$ARTIFACTS_DIR/${basename}-agent-a.md" \
    "[← Summary](SUMMARY.md) | **Agent A** | [Agent B](${basename}-agent-b.md) | [Consensus](${basename}-consensus.md)"
  prepend_nav "$ARTIFACTS_DIR/${basename}-agent-b.md" \
    "[← Summary](SUMMARY.md) | [Agent A](${basename}-agent-a.md) | **Agent B** | [Consensus](${basename}-consensus.md)"
  prepend_nav "$ARTIFACTS_DIR/${basename}-consensus.md" \
    "[← Summary](SUMMARY.md) | [Agent A](${basename}-agent-a.md) | [Agent B](${basename}-agent-b.md) | **Consensus**"

  SUMMARY_SECTIONS+=("$basename")
  elapsed
done

# -----------------------------------------------------------------------------
# Step 4 -- Generate SUMMARY.md
# -----------------------------------------------------------------------------
echo ""
echo "==> Step 4: Generating SUMMARY.md..."

IGNORE_COUNT=$(grep -cvE '^[[:space:]]*(#|$)' "$IGNORE_FILE" 2>/dev/null || echo 0)

SUMMARY_FILE="$ARTIFACTS_DIR/SUMMARY.md"
{
  echo "# UI Review Run -- ${TIMESTAMP} (single-agent mode)"
  echo ""
  echo "## Screenshots Reviewed"
  echo ""
  echo "| Screenshot | Context | Agent A | Agent B | Consensus | Preview |"
  echo "|---|---|---|---|---|---|"
  for name in "${SUMMARY_SECTIONS[@]}"; do
    desc="$name"
    if [[ -f "$CONTEXT_FILE" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        key="${line%%=*}"
        if [[ "$key" == "$name" ]]; then
          desc="${line#*=}"
          break
        fi
      done < "$CONTEXT_FILE"
    fi
    preview=""
    consensus_file="$ARTIFACTS_DIR/${name}-consensus.md"
    if [[ -f "$consensus_file" ]]; then
      preview=$(awk '
        /^\[←/ { next }
        /^---$/ { next }
        /^[[:space:]]*$/ { next }
        { print; exit }
      ' "$consensus_file")
      preview="${preview//|/\\|}"
    fi
    echo "| \`${name}\` | ${desc} | [view](${name}-agent-a.md) | [view](${name}-agent-b.md) | [view](${name}-consensus.md) | ${preview} |"
  done
  echo ""
  echo "## Configuration"
  echo ""
  echo "- **Min severity shown:** ${MIN_SEVERITY}"
  echo "- **Ignored issues:** ${IGNORE_COUNT}"
  echo "- **Mode:** single parent-agent (1 copilot call per screenshot vs 3 in orchestrate.sh)"
  echo ""
  echo "## Artifacts"
  echo ""
  echo "All files saved to: \`${ARTIFACTS_DIR}\`"
} > "$SUMMARY_FILE"
elapsed

TOTAL_CALLS=$(( SUCCESSFUL_CALLS + FAILED_CALLS ))
EQUIVALENT_MULTI=$(( ${#SUMMARY_SECTIONS[@]} * 3 ))
TOTAL_RUNTIME=$(( SECONDS - SCRIPT_START ))

echo ""
echo "==========================================="
echo " Run Complete"
echo "==========================================="
echo " Artifacts     : $ARTIFACTS_DIR"
echo " Summary       : $SUMMARY_FILE"
echo ""
echo " --- API Call Breakdown ---"
printf " %-22s %d  (%d failed)  model: claude-sonnet-4.6\n" "Parent agent calls:" "$TOTAL_CALLS" "$FAILED_CALLS"
echo " ------------------------------------------"
printf " %-22s %d\n" "Total API calls:" "$TOTAL_CALLS"
echo " Premium requests used: ~${TOTAL_CALLS}  (1 per copilot CLI call, all 1x models)"
printf " vs orchestrate.sh:    ~%d calls for %d screenshots\n" "$EQUIVALENT_MULTI" "${#SUMMARY_SECTIONS[@]}"
echo ""
echo " Total runtime : ${TOTAL_RUNTIME}s"
echo "==========================================="
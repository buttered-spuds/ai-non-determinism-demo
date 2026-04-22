#!/usr/bin/env bash
# orchestrate.sh -- Multi-agent UI review orchestrator
# Runs Playwright smoke tests, passes each screenshot to two Copilot CLI agents
# (Claude Sonnet 4.6 and GPT-5.4) for independent UI reviews, runs a consensus
# pass, then writes a SUMMARY.md.
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

# -----------------------------------------------------------------------------
# call_copilot -- timeout + exponential-backoff retry wrapper
# -----------------------------------------------------------------------------
# Prefer gtimeout (macOS/Homebrew coreutils) then timeout (Linux/GNU).
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  echo "WARNING: No 'timeout' command found (install 'coreutils' via Homebrew). Calls will not be time-bounded." >&2
  TIMEOUT_CMD=""
fi

COPILOT_TIMEOUT=${COPILOT_TIMEOUT:-120}   # seconds per individual copilot call
COPILOT_RETRIES=${COPILOT_RETRIES:-3}     # total attempts before giving up

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

# Validate against allowed values; warn and default to S3 if invalid
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

SCREENSHOTS=("$REPO_ROOT/tests/screenshots/"*.png)
if [[ ${#SCREENSHOTS[@]} -eq 0 ]]; then
  echo "ERROR: No screenshots found in $REPO_ROOT/tests/screenshots/." >&2
  echo "Run the Playwright tests and ensure screenshots are generated before retrying." >&2
  exit 1
fi

for screenshot in "${SCREENSHOTS[@]}"; do

  # Fail fast if the path contains spaces -- the @ token would be truncated
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

  # Build reviewer prompt using printf so variables expand with real newlines.
  # @<path> at the start attaches the image via the Copilot CLI.
  printf -v REVIEWER_PROMPT '@%s This screenshot shows: %s\n\n%s' \
    "$screenshot" "$description" "$REVIEWER_TEMPLATE"
  if [[ -n "$IGNORE_BLOCK" ]]; then
    printf -v REVIEWER_PROMPT '%s\n\n%s' "$REVIEWER_PROMPT" "$IGNORE_BLOCK"
  fi

  # -- Agent A and B in parallel ------------------------------------------------
  echo "    -> Calling Agent A (Claude Sonnet 4.6) and Agent B (GPT-5.4) in parallel..."

    # Agent A background
  (
    start=$SECONDS
    if REVIEW_A=$(call_copilot "claude-sonnet-4.6" "$REVIEWER_PROMPT"); then
      echo "$REVIEW_A" > "$ARTIFACTS_DIR/${basename}-agent-a.md"
      echo "    ✓ Agent A done ($(( SECONDS - start ))s)"
    else
      echo "FAILED" > "$ARTIFACTS_DIR/${basename}-agent-a.md"
      echo "    ✗ Agent A FAILED ($(( SECONDS - start ))s)"
    fi
  ) &
  PID_A=$!

  # Agent B background
  (
    start=$SECONDS
    if REVIEW_B=$(call_copilot "gpt-5.4" "$REVIEWER_PROMPT"); then
      echo "$REVIEW_B" > "$ARTIFACTS_DIR/${basename}-agent-b.md"
      echo "    ✓ Agent B done ($(( SECONDS - start ))s)"
    else
      echo "FAILED" > "$ARTIFACTS_DIR/${basename}-agent-b.md"
      echo "    ✗ Agent B FAILED ($(( SECONDS - start ))s)"
    fi
  ) &
  PID_B=$!

  echo "    -> Waiting for agents..."
  wait $PID_A $PID_B

  # Read results from files for consensus
  REVIEW_A=$(cat "$ARTIFACTS_DIR/${basename}-agent-a.md")
  REVIEW_B=$(cat "$ARTIFACTS_DIR/${basename}-agent-b.md")
  
    # Add navigation to agent files
  prepend_nav "$ARTIFACTS_DIR/${basename}-agent-a.md" \
    "[← Summary](SUMMARY.md) | **Agent A** | [Agent B](${basename}-agent-b.md) | [Consensus](${basename}-consensus.md)"
  prepend_nav "$ARTIFACTS_DIR/${basename}-agent-b.md" \
    "[← Summary](SUMMARY.md) | [Agent A](${basename}-agent-a.md) | **Agent B** | [Consensus](${basename}-consensus.md)"

  # -- Consensus pass -----------------------------------------------------------
  echo "    -> Running consensus pass..."
  printf -v CONSENSUS_PROMPT '%s\n\nMIN_SEVERITY: %s\n\n--- Agent A Review ---\n%s\n\n--- Agent B Review ---\n%s' \
    "$CONSENSUS_TEMPLATE" "$MIN_SEVERITY" "$REVIEW_A" "$REVIEW_B"

  CONSENSUS=""
  if CONSENSUS=$(call_copilot "claude-sonnet-4.6" "$CONSENSUS_PROMPT"); then
    echo "$CONSENSUS" > "$ARTIFACTS_DIR/${basename}-consensus.md"
      prepend_nav "$ARTIFACTS_DIR/${basename}-consensus.md" \
    "[← Summary](SUMMARY.md) | [Agent A](${basename}-agent-a.md) | [Agent B](${basename}-agent-b.md) | **Consensus**"
  else
    echo "    WARNING: Consensus pass failed for $basename." >&2
    echo "FAILED" > "$ARTIFACTS_DIR/${basename}-consensus.md"
    CONSENSUS="FAILED"
  fi

  SUMMARY_SECTIONS+=("$basename")
  elapsed
done

# -----------------------------------------------------------------------------
# Step 4 -- Generate SUMMARY.md
# -----------------------------------------------------------------------------
echo ""
echo "==> Step 4: Generating SUMMARY.md..."

# Count non-comment, non-blank lines in ignore.txt
IGNORE_COUNT=$(grep -cvE '^[[:space:]]*(#|$)' "$IGNORE_FILE" 2>/dev/null || echo 0)

SUMMARY_FILE="$ARTIFACTS_DIR/SUMMARY.md"
{
  echo "# UI Review Run -- ${TIMESTAMP}"
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
      # Avoid pipefail exits when no preview line exists.
      preview=$(awk '
        /^\[←/ { next }
        /^---$/ { next }
        /^[[:space:]]*$/ { next }
        { print; exit }
      ' "$consensus_file")
      # Escape markdown table delimiters to keep table formatting intact.
      preview="${preview//|/\\|}"
    fi
    echo "| \`${name}\` | ${desc} | [view](${name}-agent-a.md) | [view](${name}-agent-b.md) | [view](${name}-consensus.md) | ${preview} |"
  done
  echo ""
  echo "## Configuration"
  echo ""
  echo "- **Min severity shown:** ${MIN_SEVERITY}"
  echo "- **Ignored issues:** ${IGNORE_COUNT}"
  echo ""
  echo "## Artifacts"
  echo ""
  echo "All files saved to: \`${ARTIFACTS_DIR}\`"
} > "$SUMMARY_FILE"
elapsed
 
echo ""
echo "Review complete. Artifacts saved to: $ARTIFACTS_DIR"
echo "Summary: $SUMMARY_FILE"
echo ""
echo "Total runtime: $(( SECONDS - SCRIPT_START ))s"
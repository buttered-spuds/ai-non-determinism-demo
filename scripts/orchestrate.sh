#!/usr/bin/env bash
# orchestrate.sh — Multi-agent UI review orchestrator
# Runs Playwright smoke tests, passes each screenshot to two Copilot CLI agents
# (Claude Sonnet 4.6 and GPT-5.4) for independent UI reviews, runs a consensus
# pass, then writes a SUMMARY.md.
#
# Prerequisites:
#   - copilot CLI installed and authenticated (github.com/github/copilot-cli)
#   - npx / Node.js available

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd ""){dirname "$0"}/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# ─────────────────────────────────────────────────────────────────────────────
# Dependency check
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v copilot &>/dev/null; then
  echo "ERROR: 'copilot' CLI not found. Install it and authenticate first." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────
MIN_SEVERITY=$(grep -E '^MIN_SEVERITY=' "$SCRIPTS_DIR/config/settings.txt" 2>/dev/null \
  | cut -d'=' -f2 \
  | tr -d '[:space:]') || true
: "${MIN_SEVERITY:=S3}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARTIFACTS_DIR="$REPO_ROOT/artifacts/run-${TIMESTAMP}"
mkdir -p "$ARTIFACTS_DIR"

echo "==> Artifacts will be written to: $ARTIFACTS_DIR"
echo "==> MIN_SEVERITY: $MIN_SEVERITY"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Run Playwright
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Running Playwright tests..."
cd "$REPO_ROOT"
if ! npx playwright test; then
  echo "ERROR: Playwright tests failed. Aborting." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Build ignore list
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Review each screenshot
# ─────────────────────────────────────────────────────────────────────────────
REVIEWER_TEMPLATE=$(cat "$SCRIPTS_DIR/prompts/reviewer.txt")
CONSENSUS_TEMPLATE=$(cat "$SCRIPTS_DIR/prompts/consensus.txt")
CONTEXT_FILE="$SCRIPTS_DIR/config/context.txt"

SUMMARY_SECTIONS=()

for screenshot in "$REPO_ROOT/tests/screenshots/"*.png; do
  [[ -f "$screenshot" ]] || continue

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

  # Build reviewer prompt (the @ path attaches the image via Copilot CLI)
  REVIEWER_PROMPT="@${screenshot} This screenshot shows: ${description}\n\n${REVIEWER_TEMPLATE}"
  if [[ -n "$IGNORE_BLOCK" ]]; then
    REVIEWER_PROMPT="${REVIEWER_PROMPT}\n\n${IGNORE_BLOCK}"
  fi

  # ── Agent A: Claude Sonnet 4.6 ──────────────────────────────────────────────
echo "    -> Calling Agent A (Claude Sonnet 4.6)..."
  REVIEW_A=""
  if REVIEW_A=$(copilot --model claude-sonnet-4.6 -s -p "$REVIEWER_PROMPT" 2>&1); then
    echo "$REVIEW_A" > "$ARTIFACTS_DIR/${basename}-agent-a.md"
  else
    echo "    WARNING: Agent A failed for $basename — skipping." >&2
    echo "FAILED" > "$ARTIFACTS_DIR/${basename}-agent-a.md"
    REVIEW_A="FAILED"
  fi

  # ── Agent B: GPT-5.4 ────────────────────────────────────────────────────────
echo "    -> Calling Agent B (GPT-5.4)..."
  REVIEW_B=""
  if REVIEW_B=$(copilot --model gpt-5.4 -s -p "$REVIEWER_PROMPT" 2>&1); then
    echo "$REVIEW_B" > "$ARTIFACTS_DIR/${basename}-agent-b.md"
  else
    echo "    WARNING: Agent B failed for $basename — skipping." >&2
    echo "FAILED" > "$ARTIFACTS_DIR/${basename}-agent-b.md"
    REVIEW_B="FAILED"
  fi

  # ── Consensus pass ────────────────────────────────────────────────────────────
echo "    -> Running consensus pass..."
  CONSENSUS_PROMPT="${CONSENSUS_TEMPLATE}\n\nMIN_SEVERITY: ${MIN_SEVERITY}\n\n--- Agent A Review ---\n${REVIEW_A}\n\n--- Agent B Review ---\n${REVIEW_B}"

  CONSENSUS=""
  if CONSENSUS=$(copilot --model claude-sonnet-4.6 -s -p "$CONSENSUS_PROMPT" 2>&1); then
    echo "$CONSENSUS" > "$ARTIFACTS_DIR/${basename}-consensus.md"
  else
    echo "    WARNING: Consensus pass failed for $basename." >&2
    echo "FAILED" > "$ARTIFACTS_DIR/${basename}-consensus.md"
    CONSENSUS="FAILED"
  fi

  SUMMARY_SECTIONS+=("$basename")
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Generate SUMMARY.md
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Generating SUMMARY.md..."

IGNORE_COUNT=$(grep -cvE '^\\s*#|^\s*$' "$IGNORE_FILE" 2>/dev/null || echo 0)

SUMMARY_FILE="$ARTIFACTS_DIR/SUMMARY.md"
{
  echo "# UI Review Run — ${TIMESTAMP}"
  echo ""
  echo "## Screenshots Reviewed"
  echo ""
  echo "| Screenshot | Agent A | Agent B | Consensus |"
  echo "|---|---|---|---|"
  for name in ""){SUMMARY_SECTIONS[@]}"; do
    # Look up description for the table
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
    echo "| \\`${name}\` — ${desc} | [view](${name}-agent-a.md) | [view](${name}-agent-b.md) | [view](${name}-consensus.md) |"
  done
  echo ""
  echo "## Configuration"
  echo ""
  echo "- **Min severity shown:** ${MIN_SEVERITY}"
  echo "- **Ignored issues:** ${IGNORE_COUNT}"
  echo ""
  echo "## Artifacts"
  echo ""
  echo "All files saved to: \\`${ARTIFACTS_DIR}\`"
} > "$SUMMARY_FILE"

echo ""
echo "✅ Review complete. Artifacts saved to: $ARTIFACTS_DIR"
echo "📄 Summary: $SUMMARY_FILE"
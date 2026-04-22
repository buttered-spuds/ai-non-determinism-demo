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
REPO_ROOT="$(cd ""+"$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# ─────────────────────────────────────────────────────────────────────────────
# Dependency check
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v copilot &>/dev/null; then
  echo "ERROR: 'copilot' CLI not found. Install it and authenticate first." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Setup — read and validate MIN_SEVERITY
# ─────────────────────────────────────────────────────────────────────────────
MIN_SEVERITY=$(grep -E '^MIN_SEVERITY=' "$SCRIPTS_DIR/config/settings.txt" 2>/dev/null \
  | cut -d'=' -f2 \
  | tr -d '[:space:]') || true

# Validate against allowed values; warn and default to S3 if invalid
case "${MIN_SEVERITY}" in
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
  IGNORE_BLOCK=$'The following issues have been marked as accepted/wontfix. Do NOT raise or mention these:\n'
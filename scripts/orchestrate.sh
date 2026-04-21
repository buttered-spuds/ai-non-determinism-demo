#!/usr/bin/env bash
# orchestrate.sh — Multi-agent UI review orchestrator
# Runs Playwright smoke tests, passes each screenshot to Claude Sonnet 4.6 and
# GPT-5.4 for independent UI reviews, runs a consensus pass, then writes SUMMARY.md.
#
# Prerequisites:
#   - jq      (https://stedolan.github.io/jq/)
#   - curl
#   - base64  (GNU coreutils)
#   - ANTHROPIC_API_KEY env var set
#   - OPENAI_API_KEY env var set

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# ──────────────────────────────────────────────────────────────────────────────
# Dependency checks
# ──────────────────────────────────────────────────────────────────────────────
for cmd in jq curl base64; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: required command '$cmd' not found." >&2
    exit 1
  fi
done

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY is not set." >&2
  exit 1
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "ERROR: OPENAI_API_KEY is not set." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Setup
# ──────────────────────────────────────────────────────────────────────────────
MIN_SEVERITY=$(grep -E '^MIN_SEVERITY=' "$SCRIPTS_DIR/config/settings.txt" 2>/dev/null \
  | cut -d'=' -f2 \
  | tr -d '[:space:]') || true
: "${MIN_SEVERITY:=S3}"

ARTIFACTS_DIR="$REPO_ROOT/artifacts/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ARTIFACTS_DIR"

echo "==> Artifacts will be written to: $ARTIFACTS_DIR"
echo "==> MIN_SEVERITY: $MIN_SEVERITY"

# ──────────────────────────────────────────────────────────────────────────────
# Step 1 — Run Playwright
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Running Playwright tests..."
cd "$REPO_ROOT"
if ! npx playwright test; then
  echo "ERROR: Playwright tests failed. Aborting." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 2 — Build ignore list
# ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# Step 3 — Review each screenshot
# ──────────────────────────────────────────────────────────────────────────────
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

  # Build reviewer prompt
  REVIEWER_PROMPT="This screenshot shows: ${description}

${REVIEWER_TEMPLATE}"
  if [[ -n "$IGNORE_BLOCK" ]]; then
    REVIEWER_PROMPT="${REVIEWER_PROMPT}

${IGNORE_BLOCK}"
  fi

  # Encode screenshot as base64 (cross-platform: avoids GNU-only -w 0 flag)
  IMG_B64=$(base64 < "$screenshot" | tr -d '\n')

  # ── Agent A: Claude Sonnet 4.6 ──────────────────────────────────────────────
  echo "    -> Calling Claude Sonnet 4.6..."
  CLAUDE_PAYLOAD=$(jq -n \
    --arg model "claude-sonnet-4-6" \
    --arg prompt "$REVIEWER_PROMPT" \
    --arg img_data "$IMG_B64" \
    '{
      model: $model,
      max_tokens: 2048,
      messages: [{
        role: "user",
        content: [
          {
            type: "image",
            source: {
              type: "base64",
              media_type: "image/png",
              data: $img_data
            }
          },
          {
            type: "text",
            text: $prompt
          }
        ]
      }]
    }')

  CLAUDE_RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$CLAUDE_PAYLOAD")

  REVIEW_A=$(echo "$CLAUDE_RESPONSE" \
    | jq -r '.content[0].text // "ERROR: \(.error.message // "Unknown error")"')
  echo "$REVIEW_A" > "$ARTIFACTS_DIR/${basename}-review-a.md"

  # ── Agent B: GPT-5.4 ────────────────────────────────────────────────────────
  echo "    -> Calling GPT-5.4..."
  GPT_PAYLOAD=$(jq -n \
    --arg model "gpt-5.4" \
    --arg prompt "$REVIEWER_PROMPT" \
    --arg img_url "data:image/png;base64,${IMG_B64}" \
    '{
      model: $model,
      messages: [{
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: {
              url: $img_url
            }
          },
          {
            type: "text",
            text: $prompt
          }
        ]
      }]
    }')

  GPT_RESPONSE=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$GPT_PAYLOAD")

  REVIEW_B=$(echo "$GPT_RESPONSE" \
    | jq -r '.choices[0].message.content // "ERROR: \(.error.message // "Unknown error")"')
  echo "$REVIEW_B" > "$ARTIFACTS_DIR/${basename}-review-b.md"

  # ── Consensus pass ──────────────────────────────────────────────────────────
  echo "    -> Running consensus pass..."
  CONSENSUS_PROMPT="${CONSENSUS_TEMPLATE/MIN_SEVERITY/$MIN_SEVERITY}

---
Agent A review:
${REVIEW_A}

---
Agent B review:
${REVIEW_B}"

  CONSENSUS_PAYLOAD=$(jq -n \
    --arg model "claude-sonnet-4-6" \
    --arg prompt "$CONSENSUS_PROMPT" \
    '{
      model: $model,
      max_tokens: 2048,
      messages: [{
        role: "user",
        content: $prompt
      }]
    }')

  CONSENSUS_RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$CONSENSUS_PAYLOAD")

  CONSENSUS=$(echo "$CONSENSUS_RESPONSE" \
    | jq -r '.content[0].text // "ERROR: \(.error.message // "Unknown error")"')
  echo "$CONSENSUS" > "$ARTIFACTS_DIR/${basename}-consensus.md"

  SUMMARY_SECTIONS+=("$basename")
done

# ──────────────────────────────────────────────────────────────────────────────
# Step 4 — Generate SUMMARY.md
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Generating SUMMARY.md..."
SUMMARY_FILE="$ARTIFACTS_DIR/SUMMARY.md"
{
  echo "# UI Review Summary"
  echo ""
  echo "Run: $(date)"
  echo ""
  echo "MIN_SEVERITY: ${MIN_SEVERITY}"
  echo ""
  for name in "${SUMMARY_SECTIONS[@]}"; do
    echo "## ${name}"
    echo ""
    cat "$ARTIFACTS_DIR/${name}-consensus.md"
    echo ""
    echo "---"
    echo ""
  done
} > "$SUMMARY_FILE"

echo ""
echo "==> Done! Summary at: $SUMMARY_FILE"

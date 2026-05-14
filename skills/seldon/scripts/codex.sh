#!/usr/bin/env bash
# Seldon judge runner via the Codex plugin companion (codex-plugin-cc).
# Prerequisites: Codex plugin installed in Claude Code (`/codex:setup`).
# Optional: JUDGE_MODEL, JUDGE_REASONING override defaults.
#
# Usage:
#   bash scripts/codex.sh [--focus balanced|architecture|evaluation|product|operations|safety] \
#        <plan-file> [supporting-file ...]
#
# Emits verdict JSON on stdout matching ../seldon.schema.json.

set -euo pipefail

# --- Find codex-companion.mjs ---
find_companion() {
  local candidate
  candidate="$(find ~/.claude/plugins -name "codex-companion.mjs" -path "*/scripts/*" 2>/dev/null | head -1)"
  [[ -n "$candidate" ]] && { echo "$candidate"; return; }
  return 1
}

CODEX_COMPANION="$(find_companion)" || {
  echo "codex-companion.mjs not found — install the Codex plugin and run /codex:setup" >&2
  exit 1
}

# --- Config ---
JUDGE_REASONING="${JUDGE_REASONING:-xhigh}"

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [--focus balanced|architecture|evaluation|product|operations|safety] <plan-file> [supporting-file ...]" >&2
  exit "${1:-1}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
schema_path="$script_dir/../seldon.schema.json"
[[ -f "$schema_path" ]] || schema_path="$script_dir/seldon.schema.json"
[[ -f "$schema_path" ]] || { echo "seldon.schema.json not found in skill root or scripts/" >&2; exit 1; }
focus="balanced"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --focus)
      [[ $# -lt 2 ]] && { echo "Missing value for --focus" >&2; usage; }
      focus="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

[[ $# -lt 1 ]] && usage

case "$focus" in
  balanced|architecture|evaluation|product|operations|safety) ;;
  *) echo "Unsupported focus: $focus" >&2; usage ;;
esac

# --- Read files ---
primary_plan="$1"; shift
[[ -f "$primary_plan" ]] || { echo "Missing file: $primary_plan" >&2; exit 1; }
plan_content="$(cat "$primary_plan")"

supporting_content=""
for path in "$@"; do
  [[ -f "$path" ]] || { echo "Missing file: $path" >&2; exit 1; }
  supporting_content+="--- $path ---"$'\n'"$(cat "$path")"$'\n\n'
done

schema="$(cat "$schema_path")"

# --- Focus instructions ---
case "$focus" in
  architecture) focus_inst='Emphasize architecture and implementation realism. Be strict about service boundaries, dependency sprawl, migration risk, and hidden integration work.' ;;
  evaluation)   focus_inst='Emphasize evaluation rigor and observability. Be strict about measurable success criteria, regression detection, and testability.' ;;
  product)      focus_inst='Emphasize product risk and delivery quality. Be strict about user-visible failure modes, sequencing, and scope realism.' ;;
  operations)   focus_inst='Emphasize rollout and operational durability. Be strict about ownership, alerting, rollback, failure handling, and maintenance burden.' ;;
  safety)       focus_inst='Emphasize safety, privacy, and security. Be strict about hallucination controls, citation integrity, access assumptions, and unsafe fallback behavior.' ;;
  *)            focus_inst='Keep the review balanced across repo fit, correctness, sequencing, evaluation, operations, and safety. Prioritize concrete evidence over speculation.' ;;
esac

# --- Build prompt ---
prompt_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$stderr_file"' EXIT

cat > "$prompt_file" << EOF
You are an independent plan reviewer. Read the plan, inspect only the workspace files
needed to verify its claims, then return ONLY valid JSON matching the provided schema —
no markdown fences, no wrapping text, no extra keys.

Focus: $focus. $focus_inst

Plan file ($primary_plan):
$plan_content

${supporting_content:+Supporting files:
$supporting_content}

Output schema (return JSON matching this exactly):
$schema
EOF

# --- Run via codex-companion ---
workspace_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

model_flag=""
[[ -n "${JUDGE_MODEL:-}" ]] && model_flag="--model $JUDGE_MODEL"

raw_json="$(node "$CODEX_COMPANION" task \
  --json \
  --effort "$JUDGE_REASONING" \
  --cwd "$workspace_root" \
  ${model_flag} \
  --prompt-file "$prompt_file" 2>"$stderr_file")" || {
  cat "$stderr_file" >&2
  exit 1
}

# Extract rawOutput (model's final message) from companion JSON envelope
content="$(printf '%s' "$raw_json" | python3 -c \
  'import json,sys; r=json.load(sys.stdin); print(r["rawOutput"])' 2>/dev/null)" || {
  echo "Failed to parse companion response:" >&2
  printf '%s\n' "$raw_json" >&2
  exit 1
}

# Strip markdown fence if present, then validate JSON
content="$(printf '%s' "$content" | python3 -c '
import sys, re, json
text = sys.stdin.read().strip()
m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
text = m.group(1) if m else text
try:
    json.loads(text)
except json.JSONDecodeError as e:
    print(f"Output is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
print(text)
')" || exit 1

printf '%s\n' "$content"

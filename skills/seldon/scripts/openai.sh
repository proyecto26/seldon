#!/usr/bin/env bash
# Seldon judge runner for the OpenAI Chat Completions API (via curl).
# Prerequisites: OPENAI_API_KEY environment variable; python3 on PATH.
# Optional: JUDGE_MODEL overrides the default model.
#
# Usage:
#   bash scripts/openai.sh [--focus balanced|architecture|evaluation|product|operations|safety] \
#        <plan-file> [supporting-file ...]
#
# Emits verdict JSON on stdout matching ../seldon.schema.json.

set -euo pipefail

# --- Config (override via environment) ---
JUDGE_MODEL="${JUDGE_MODEL:-gpt-4o}"

# --- Argument parsing ---
usage() {
  echo "Usage: $0 [--focus balanced|architecture|evaluation|product|operations|safety] <plan-file> [supporting-file ...]" >&2
  exit "${1:-1}"
}

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

[[ -z "${OPENAI_API_KEY:-}" ]] && { echo "OPENAI_API_KEY is not set" >&2; exit 1; }

# --- Read plan file ---
primary_plan="$1"; shift
[[ -f "$primary_plan" ]] || { echo "Missing file: $primary_plan" >&2; exit 1; }
plan_content="$(cat "$primary_plan")"

supporting_content=""
for path in "$@"; do
  [[ -f "$path" ]] || { echo "Missing file: $path" >&2; exit 1; }
  supporting_content+="--- $path ---"$'\n'"$(cat "$path")"$'\n\n'
done

# --- Focus instructions ---
case "$focus" in
  architecture) focus_inst="Emphasize architecture and implementation realism. Be strict about service boundaries, dependency sprawl, migration risk, and hidden integration work." ;;
  evaluation)   focus_inst="Emphasize evaluation rigor and observability. Be strict about measurable success criteria, regression detection, and testability." ;;
  product)      focus_inst="Emphasize product risk and delivery quality. Be strict about user-visible failure modes, sequencing, and scope realism." ;;
  operations)   focus_inst="Emphasize rollout and operational durability. Be strict about ownership, alerting, rollback, failure handling, and maintenance burden." ;;
  safety)       focus_inst="Emphasize safety, privacy, and security. Be strict about hallucination controls, citation integrity, access assumptions, and unsafe fallback behavior." ;;
  *)            focus_inst="Keep the review balanced across repo fit, correctness, sequencing, evaluation, operations, and safety. Prioritize concrete evidence over speculation." ;;
esac

# --- Read schema ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
schema_path="$script_dir/../seldon.schema.json"
[[ -f "$schema_path" ]] || schema_path="$script_dir/seldon.schema.json"
[[ -f "$schema_path" ]] || { echo "seldon.schema.json not found in skill root or scripts/" >&2; exit 1; }
schema="$(cat "$schema_path")"

# --- Build request ---
system_prompt="You are an independent plan reviewer. Evaluate the plan based on the files provided in this prompt. You only have access to the files explicitly passed here — you cannot traverse the workspace. Return JSON matching the provided schema. Focus: $focus. $focus_inst"

user_prompt="Plan file ($primary_plan):
$plan_content

${supporting_content:+Supporting files:
$supporting_content}

Output schema:
$schema

Return ONLY valid JSON matching the schema. No markdown wrapping."

# Escape for JSON
system_escaped="$(printf '%s' "$system_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
user_escaped="$(printf '%s' "$user_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"

response="$(curl -s https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "{
    \"model\": \"$JUDGE_MODEL\",
    \"temperature\": 0.2,
    \"response_format\": {\"type\": \"json_object\"},
    \"messages\": [
      {\"role\": \"system\", \"content\": $system_escaped},
      {\"role\": \"user\", \"content\": $user_escaped}
    ]
  }")"

# Detect API-level errors before parsing content
if printf '%s' "$response" | python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(1 if "error" in r else 0)' 2>/dev/null; then
  : # ok
else
  echo "OpenAI API error:" >&2
  printf '%s\n' "$response" >&2
  exit 1
fi

# Extract content
content="$(printf '%s' "$response" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["choices"][0]["message"]["content"])' 2>/dev/null)" || {
  echo "Failed to parse OpenAI response:" >&2
  printf '%s\n' "$response" >&2
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
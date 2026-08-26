#!/usr/bin/env bash
# Seldon judge runner via OpenAI Codex.
#
# Two backends, auto-selected (override with SELDON_CODEX_BACKEND=cli|companion):
#   cli        — `codex` CLI on PATH (works in Codex, Cursor, Copilot, Claude Code, any shell).
#                Uses `codex exec --output-schema` so the verdict shape is enforced by Codex.
#   companion  — `codex-companion.mjs` from the Codex plugin for Claude Code
#                (https://github.com/openai/codex-plugin-cc, `/codex:setup`).
#
# Optional: JUDGE_MODEL, JUDGE_REASONING (default xhigh) override defaults.
#
# Usage:
#   bash scripts/codex.sh [--focus balanced|architecture|evaluation|product|operations|safety] \
#        <plan-file> [supporting-file ...]
#   bash scripts/codex.sh --probe      # exit 0 if a usable backend exists, 1 otherwise
#
# Output contract (identical for both backends):
#   stdout — exactly one JSON object matching ../seldon.schema.json, newline-terminated.
#   stderr — diagnostics only. Non-zero exit on any failure.

set -euo pipefail

# --- Config ---
# `xhigh` is accepted by both backends: the codex CLI's model_reasoning_effort enum is
# none|minimal|low|medium|high|xhigh (codex-cli 0.130, verified with `codex exec -c
# model_reasoning_effort="xhigh"`), and the companion passes it through as --effort.
JUDGE_REASONING="${JUDGE_REASONING:-xhigh}"
BACKEND="${SELDON_CODEX_BACKEND:-auto}"

# --- Backend discovery ---
find_companion() {
  local candidate
  candidate="$(find ~/.claude/plugins -name "codex-companion.mjs" -path "*/scripts/*" 2>/dev/null | head -1)"
  [[ -n "$candidate" ]] && { echo "$candidate"; return; }
  return 1
}

# The CLI backend needs every one of these `codex exec` flags. Probe the binary's
# help text so an old or unrelated `codex` on PATH is never selected blindly.
REQUIRED_EXEC_FLAGS=(--sandbox --cd --skip-git-repo-check --output-schema --output-last-message)
probe_cli() {
  local bin="$1" help flag
  help="$("$bin" exec --help 2>/dev/null)" || return 1
  for flag in "${REQUIRED_EXEC_FLAGS[@]}"; do
    grep -q -- "$flag" <<<"$help" || { echo "codex CLI at $bin lacks 'exec $flag'" >&2; return 1; }
  done
}

CODEX_CLI=""
CODEX_COMPANION=""
case "$BACKEND" in
  auto)
    if CODEX_CLI="$(command -v codex 2>/dev/null)" && probe_cli "$CODEX_CLI"; then
      BACKEND="cli"
    # The companion is a Claude Code plugin and runs with that installation's
    # configuration and credentials. Auto mode only reaches for it from inside a
    # Claude Code session (CLAUDECODE is set by Claude Code); elsewhere it must be
    # requested explicitly with SELDON_CODEX_BACKEND=companion.
    elif [[ -n "${CLAUDECODE:-}" ]] && CODEX_COMPANION="$(find_companion)"; then
      [[ -n "$CODEX_CLI" ]] && echo "codex CLI on PATH is incompatible; falling back to companion" >&2
      BACKEND="companion"
    else
      echo "No usable Codex backend: install a current codex CLI (npm i -g @openai/codex)${CLAUDECODE:+, or the Codex plugin for Claude Code (/codex:setup)}" >&2
      exit 1
    fi ;;
  cli)
    CODEX_CLI="$(command -v codex 2>/dev/null)" || { echo "codex CLI not found on PATH" >&2; exit 1; }
    probe_cli "$CODEX_CLI" || exit 1 ;;
  companion)
    CODEX_COMPANION="$(find_companion)" || { echo "codex-companion.mjs not found — install the Codex plugin and run /codex:setup" >&2; exit 1; } ;;
  *)
    echo "Unknown SELDON_CODEX_BACKEND: $BACKEND (expected cli|companion)" >&2; exit 1 ;;
esac

if [[ "$BACKEND" == "cli" ]]; then
  echo "[seldon] backend=cli ($("$CODEX_CLI" --version 2>/dev/null || echo "$CODEX_CLI"))" >&2
else
  echo "[seldon] backend=companion ($CODEX_COMPANION)" >&2
fi

# `--probe`: report whether a usable backend exists (exit 0) without running a review.
# validate.sh uses this so auto judge selection applies the same compatibility rules.
[[ "${1:-}" == "--probe" ]] && exit 0

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

# --- Build prompt (shared) ---
prompt_file="$(mktemp)"
stderr_file="$(mktemp)"
last_msg_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$stderr_file" "$last_msg_file"' EXIT

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

workspace_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"

# --- Run backend; each writes the model's final message to $last_msg_file ---
if [[ "$BACKEND" == "cli" ]]; then
  cli_args=(exec --sandbox read-only --cd "$workspace_root" --skip-git-repo-check
            --output-schema "$schema_path" --output-last-message "$last_msg_file"
            -c "model_reasoning_effort=\"$JUDGE_REASONING\"")
  [[ -n "${JUDGE_MODEL:-}" ]] && cli_args+=(--model "$JUDGE_MODEL")
  # Prompt is passed on stdin ("-") so long plans never hit argv limits.
  "$CODEX_CLI" "${cli_args[@]}" - < "$prompt_file" >"$stderr_file" 2>&1 || {
    echo "codex exec failed:" >&2
    cat "$stderr_file" >&2
    exit 1
  }
  [[ -s "$last_msg_file" ]] || {
    echo "codex exec produced no final message:" >&2
    cat "$stderr_file" >&2
    exit 1
  }
else
  model_flag=()
  [[ -n "${JUDGE_MODEL:-}" ]] && model_flag=(--model "$JUDGE_MODEL")
  raw_json="$(node "$CODEX_COMPANION" task \
    --json \
    --effort "$JUDGE_REASONING" \
    --cwd "$workspace_root" \
    "${model_flag[@]}" \
    --prompt-file "$prompt_file" 2>"$stderr_file")" || {
    cat "$stderr_file" >&2
    exit 1
  }
  # Extract rawOutput (model's final message) from companion JSON envelope
  printf '%s' "$raw_json" | python3 -c \
    'import json,sys; r=json.load(sys.stdin); sys.stdout.write(r["rawOutput"])' >"$last_msg_file" 2>/dev/null || {
    echo "Failed to parse companion response:" >&2
    printf '%s\n' "$raw_json" >&2
    exit 1
  }
fi

# --- Shared post-processing: strip fences, verify JSON, validate against schema, emit ---
# Validation uses `jsonschema` when importable; otherwise a dependency-free checker
# that covers everything seldon.schema.json uses (type, required, enum, bounds,
# additionalProperties, items, $ref into $defs). Either way, schema-invalid
# verdicts exit non-zero instead of being passed to the caller as valid.
content="$(python3 - "$last_msg_file" "$schema_path" <<'PY'
import sys, re, json
for s in (sys.stdout, sys.stderr):
    if hasattr(s, "reconfigure"):
        s.reconfigure(encoding="utf-8", errors="replace")

text = open(sys.argv[1], encoding="utf-8").read().strip()
m = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.DOTALL)
text = m.group(1) if m else text
try:
    data = json.loads(text)
except json.JSONDecodeError as e:
    print(f"Output is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

schema = json.load(open(sys.argv[2], encoding="utf-8"))

def fallback_errors(node, inst, path, root):
    if "$ref" in node:
        target = root
        for part in node["$ref"].lstrip("#/").split("/"):
            target = target[part]
        yield from fallback_errors(target, inst, path, root); return
    t = node.get("type")
    types = {"object": dict, "array": list, "string": str, "number": (int, float), "boolean": bool}
    if t and (not isinstance(inst, types[t]) or (t == "number" and isinstance(inst, bool))):
        yield f"{path or '<root>'}: expected {t}"; return
    if "enum" in node and inst not in node["enum"]:
        yield f"{path}: {inst!r} not in {node['enum']}"
    if isinstance(inst, str) and len(inst) < node.get("minLength", 0):
        yield f"{path}: shorter than minLength {node['minLength']}"
    if isinstance(inst, (int, float)) and not isinstance(inst, bool):
        if "minimum" in node and inst < node["minimum"]: yield f"{path}: below minimum {node['minimum']}"
        if "maximum" in node and inst > node["maximum"]: yield f"{path}: above maximum {node['maximum']}"
    if isinstance(inst, dict):
        for key in node.get("required", []):
            if key not in inst: yield f"{path or '<root>'}: missing required '{key}'"
        props = node.get("properties", {})
        if node.get("additionalProperties") is False:
            for key in inst:
                if key not in props: yield f"{path or '<root>'}: unexpected property '{key}'"
        for key, sub in props.items():
            if key in inst: yield from fallback_errors(sub, inst[key], f"{path}.{key}" if path else key, root)
    if isinstance(inst, list) and "items" in node:
        for i, item in enumerate(inst):
            yield from fallback_errors(node["items"], item, f"{path}[{i}]", root)

try:
    from jsonschema import Draft202012Validator
    errors = [f"{'.'.join(str(p) for p in e.path) or '<root>'}: {e.message}"
              for e in Draft202012Validator(schema).iter_errors(data)]
except ImportError:
    errors = list(fallback_errors(schema, data, "", schema))

if errors:
    print(f"Output violates seldon.schema.json ({len(errors)} error(s)):", file=sys.stderr)
    for err in errors[:10]:
        print("  - " + err, file=sys.stderr)
    sys.exit(1)
print(text)
PY
)" || exit 1

printf '%s\n' "$content"

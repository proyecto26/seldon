#!/usr/bin/env bash
# Run a seldon judge end-to-end and validate its JSON against seldon.schema.json.
#
# Usage:
#   bash scripts/validate.sh [--judge auto|anthropic|openai|codex] \
#                            [--focus balanced|architecture|evaluation|product|operations|safety] \
#                            <plan-file> [supporting-file ...]
#
# Examples:
#   bash scripts/validate.sh examples/demo_plan.md
#   bash scripts/validate.sh --judge codex examples/demo_plan.md
#   bash scripts/validate.sh --judge openai --focus safety plan.md docs/api.md
#
# Requires:
#   - The runner's own prerequisites (API key or `codex` CLI).
#   - python3 with the `jsonschema` package (see ../requirements.txt).
#     The script will look for `.venv/bin/python` inside the skill root first,
#     then fall back to the `python3` on PATH.

set -euo pipefail

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" >&2; exit "${1:-1}"; }

judge="auto"
focus="balanced"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --judge) judge="$2"; shift 2 ;;
    --focus) focus="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

[[ $# -lt 1 ]] && { echo "Missing plan file" >&2; usage; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_dir="$(cd "$script_dir/.." && pwd -P)"
schema="$skill_dir/seldon.schema.json"
[[ -f "$schema" ]] || { echo "Missing $schema" >&2; exit 1; }

# Resolve judge
resolve_auto() {
  if command -v codex >/dev/null 2>&1; then echo codex; return; fi
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { echo anthropic; return; }
  [[ -n "${OPENAI_API_KEY:-}"    ]] && { echo openai;    return; }
  echo ""
}

if [[ "$judge" == "auto" ]]; then
  judge="$(resolve_auto)"
  [[ -z "$judge" ]] && { echo "No judge available (need codex CLI or ANTHROPIC_API_KEY or OPENAI_API_KEY)" >&2; exit 1; }
fi

case "$judge" in
  anthropic|openai|codex) ;;
  *) echo "Unknown judge: $judge" >&2; exit 1 ;;
esac

runner="$script_dir/$judge.sh"
[[ -x "$runner" || -f "$runner" ]] || { echo "Missing runner: $runner" >&2; exit 1; }

# Pick python: prefer venv inside the skill dir
if [[ -x "$skill_dir/.venv/bin/python" ]]; then
  py="$skill_dir/.venv/bin/python"
else
  py="python3"
fi

# Confirm jsonschema is available
if ! "$py" -c 'import jsonschema' 2>/dev/null; then
  echo "jsonschema not installed for $py" >&2
  echo "Hint: python3 -m venv $skill_dir/.venv && $skill_dir/.venv/bin/pip install -r $skill_dir/requirements.txt" >&2
  exit 1
fi

# Run the judge, capture stdout + stderr
out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$out_file" "$err_file"' EXIT

echo "==> Running judge=$judge focus=$focus on $1" >&2
if ! bash "$runner" --focus "$focus" "$@" >"$out_file" 2>"$err_file"; then
  echo "Runner failed:" >&2
  cat "$err_file" >&2
  exit 1
fi

# Validate (pass out_file as argv to avoid stdin redirection clash with heredoc)
"$py" - "$schema" "$judge" "$out_file" <<'PY'
import json, sys
from jsonschema import Draft202012Validator

schema_path, label, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out_path) as fh:
    raw = fh.read()

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"[{label}] FAIL: stdout is not valid JSON ({exc})")
    print("First 200 chars:", raw[:200])
    sys.exit(2)

with open(schema_path) as fh:
    schema = json.load(fh)

errors = sorted(Draft202012Validator(schema).iter_errors(data), key=lambda e: list(e.path))
if errors:
    print(f"[{label}] FAIL: {len(errors)} schema violation(s)")
    for err in errors[:5]:
        loc = ".".join(str(p) for p in err.path) or "<root>"
        print(f"  - {loc}: {err.message}")
    sys.exit(1)

conf = data["confidence"]
filled = round(conf * 20)
bar = "█" * filled + "░" * (20 - filled)
label_emoji = "\U0001F7E2" if conf >= 0.9 else "\U0001F7E1" if conf >= 0.7 else "\U0001F7E0" if conf >= 0.5 else "\U0001F534"
print(f"[{label}] OK  verdict={data['verdict']}  {label_emoji} confidence={conf:.2f}  {bar}")
print(f"        strengths={len(data['strengths'])}  "
      f"blocking={len(data['blocking_findings'])}  "
      f"non_blocking={len(data['non_blocking_findings'])}  "
      f"open_questions={len(data['open_questions'])}")
print(f"        summary: {data['summary'][:140]}")
PY

# On success, also dump the raw JSON to stdout for piping
cat "$out_file"

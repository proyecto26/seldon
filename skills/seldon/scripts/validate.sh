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
#   - The runner's own prerequisites (API key, or `codex` CLI / Codex companion plugin).
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

# Resolve judge candidates. In auto mode every available judge is a candidate, in
# priority order, and a runtime failure of one moves on to the next: an optional
# dependency that probes fine but fails to run must not turn into a hard failure
# when API judges are available.
candidates=()
if [[ "$judge" == "auto" ]]; then
  # codex.sh --probe applies the runner's own backend-compatibility rules.
  bash "$script_dir/codex.sh" --probe >/dev/null 2>&1 && candidates+=(codex)
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && candidates+=(anthropic)
  [[ -n "${OPENAI_API_KEY:-}"    ]] && candidates+=(openai)
  [[ ${#candidates[@]} -gt 0 ]] || { echo "No judge available (need a usable codex CLI, ANTHROPIC_API_KEY, or OPENAI_API_KEY)" >&2; exit 1; }
else
  case "$judge" in
    anthropic|openai|codex) candidates=("$judge") ;;
    *) echo "Unknown judge: $judge" >&2; exit 1 ;;
  esac
fi

# Pick python: prefer venv inside the skill dir
if [[ -x "$skill_dir/.venv/bin/python" ]]; then
  py="$skill_dir/.venv/bin/python"          # POSIX venv layout
elif [[ -x "$skill_dir/.venv/Scripts/python.exe" ]]; then
  py="$skill_dir/.venv/Scripts/python.exe"  # Windows venv layout
else
  py="python3"
fi

# Confirm jsonschema is available
if ! "$py" -c 'import jsonschema' 2>/dev/null; then
  echo "jsonschema not installed for $py" >&2
  echo "Hint: python3 -m venv $skill_dir/.venv && $skill_dir/.venv/bin/pip install -r $skill_dir/requirements.txt" >&2
  exit 1
fi

# Run the judge(s), capture stdout + stderr
out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$out_file" "$err_file"' EXIT

# Validate a runner's stdout against the schema and print the summary line.
# Returns non-zero on invalid JSON or schema violations (message printed to stdout).
validate_verdict() {
  # out_file passed as argv to avoid stdin redirection clash with the heredoc
  "$py" - "$schema" "$1" "$2" <<'PY'
import json, sys
from jsonschema import Draft202012Validator

# Emoji/box characters below must survive non-UTF-8 consoles (e.g. Windows cp1252)
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

schema_path, label, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(out_path, encoding="utf-8") as fh:
    raw = fh.read()

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"[{label}] FAIL: stdout is not valid JSON ({exc})")
    print("First 200 chars:", raw[:200])
    sys.exit(2)

with open(schema_path, encoding="utf-8") as fh:
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
}

judge=""
for candidate in "${candidates[@]}"; do
  runner="$script_dir/$candidate.sh"
  [[ -f "$runner" ]] || { echo "Missing runner: $runner" >&2; continue; }
  echo "==> Running judge=$candidate focus=$focus on $1" >&2
  if bash "$runner" --focus "$focus" "$@" >"$out_file" 2>"$err_file"; then
    # A candidate counts as successful only if its output also validates. Only the
    # winning candidate's summary reaches stdout; failed validations go to stderr so
    # stdout stays machine-readable (summary line + raw JSON) in the fallback path.
    if summary="$(validate_verdict "$candidate" "$out_file")"; then
      printf '%s\n' "$summary"; judge="$candidate"; break
    fi
    printf '%s\n' "$summary" >&2
  else
    echo "Runner $candidate failed:" >&2
    cat "$err_file" >&2
  fi
  [[ ${#candidates[@]} -gt 1 ]] && echo "==> Trying next judge" >&2
done
[[ -n "$judge" ]] || { echo "All candidate judges failed or returned invalid verdicts: ${candidates[*]}" >&2; exit 1; }

# On success, also dump the raw JSON to stdout for piping
cat "$out_file"

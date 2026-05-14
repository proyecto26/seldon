# Plan: Add a `/seldon` smoke-test harness

## Goal
Verify each of the three judge runners (`scripts/anthropic.sh`,
`scripts/openai.sh`, `scripts/codex.sh`) returns verdict JSON that
conforms to `seldon.schema.json`.

## Approach
1. Treat this file as the plan-under-review.
2. Invoke a runner with `--focus balanced`.
3. Pipe stdout into `scripts/validate.sh` (or the equivalent
   `python -m jsonschema` invocation) and check exit status.

## Out of scope
- Cost tracking, retries, caching.
- Parallel multi-judge fan-out.

## Risks
- Codex requires the plan path to be inside the git workspace.
- The Anthropic and OpenAI runners shell out to `python3` for JSON
  escaping; both need `python3` on PATH (stdlib only).

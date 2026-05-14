---
name: seldon
description: This skill should be used when the user asks to "review my plan", "judge this spec", "verify this design doc", "second opinion on this RFC", "run seldon", or wants an independent verdict on a plan, spec, or design document. Sends the provided files to an external judge (Anthropic, OpenAI, or Codex via plugin) or performs an inline workspace review, and returns a structured verdict. Note: API runners (anthropic, openai) can only evaluate files explicitly passed to them — only the codex runner and the inline reviewer can traverse the workspace.
---

# Seldon — Independent Plan Reviewer

Act as an independent reviewer evaluating a plan written by another agent or human. Judge it on its merits — do not co-author, rewrite, or soften findings.

## Inputs to gather

Before starting, confirm the following with the user:

- **Plan file** (required): the primary document to review (Markdown, PDF, etc.). If the user does not provide one, ask for it before continuing.
- **Supporting files** (optional): code, tests, configs, or related docs the plan references.
- **Focus mode** (optional, default `balanced`): one of `balanced`, `architecture`, `evaluation`, `product`, `operations`, `safety`.
- **Judge** (optional, default `auto`): one of `auto`, `anthropic`, `openai`, `codex`, `inline`.

## Workflow

### Step 1 — Choose a judge

This skill ships with three external judge runners in its own `scripts/` directory, alongside this `SKILL.md`:

| Script | Judge | Default model | Required |
|--------|-------|---------------|----------|
| `scripts/codex.sh` | Codex via plugin companion | codex default | codex plugin installed |
| `scripts/anthropic.sh` | Anthropic API (Claude) | `claude-sonnet-4-6` | `ANTHROPIC_API_KEY` |
| `scripts/openai.sh` | OpenAI API (GPT) | `gpt-4o` | `OPENAI_API_KEY` |

All three runners depend on the JSON Schema file **`seldon.schema.json`**, which defines the verdict shape (see Step 4). The scripts look for it first in the skill root (next to this `SKILL.md`), then in `scripts/`. If neither location has it, the scripts exit with an error. Verify the schema is present before invoking any runner; if missing, surface this to the user as a setup error rather than retrying.

**Scope of each runner**:
- `codex` — spawns a Codex agent rooted at the caller's git workspace (`git rev-parse --show-toplevel`, falling back to `pwd`). The agent can read other workspace files to verify claims. The plan path itself need not be inside the workspace, but Codex's verification value drops if the workspace is unrelated to the plan.
- `anthropic` / `openai` — see only the files explicitly passed as arguments; their system prompt states this constraint. Pass all relevant supporting files (schemas, configs, referenced code) as extra arguments if workspace verification matters.

Resolve the judge as follows:

1. If the user picked an explicit judge (`anthropic`, `openai`, `codex`, or `inline`), use that and skip the probe.
2. Otherwise (`auto`), probe in this order and pick the first available:
   - `codex-companion.mjs` found in `~/.claude/plugins` → run `scripts/codex.sh`
   - `ANTHROPIC_API_KEY` is set → run `scripts/anthropic.sh`
   - `OPENAI_API_KEY` is set → run `scripts/openai.sh`
   - None available → fall through to inline review (Step 2 onward).

When invoking a script, resolve the absolute path to this skill's directory and invoke:

```bash
bash <skill-dir>/scripts/<judge>.sh --focus <mode> <plan-file> [supporting-files...]
```

Calling via `bash` keeps the runner working regardless of file mode, so no `chmod +x` step is required.

**Optional environment overrides** read by the scripts:

- `JUDGE_MODEL` — override the default model on any runner.
- `JUDGE_REASONING` — codex only (default `xhigh`).

Each script returns JSON matching the verdict shape described in Step 4 on stdout. Parse the JSON and skip directly to Step 4.

If the chosen script exits non-zero, surface the stderr verbatim, explain the likely cause (missing schema, missing API key, file outside workspace, network failure, etc.), and ask the user whether to retry with a different judge or fall back to inline review. Never silently downgrade.

### Step 2 — Read the plan and workspace context

Reach this step only when running an inline review.

1. Read the primary plan file. Then read each supporting file the user listed.
2. Use Glob, Grep, and Read to verify whether the plan's claims match the actual codebase — file paths, APIs, dependencies, config, schema. Inspect only what is needed; do not explore exhaustively.

### Step 3 — Evaluate against the rubric

| Dimension | What to check |
|-----------|--------------|
| Repo fit | Does the plan match this workspace's code, docs, dependencies, and current state? |
| Technical correctness | Are architecture, APIs, data flows, and dependencies coherent? |
| Scope & sequencing | Are prerequisites identified and rollout steps realistic? |
| Evaluation | Are metrics, tests, and observability adequate for the proposed change? |
| Safety & operations | Are privacy, security, failure modes, and rollback handled? |

Apply the chosen focus mode:

- **balanced** (default): Cover all dimensions evenly. Prioritize concrete evidence over speculation.
- **architecture**: Emphasize implementation realism. Be strict about service boundaries, dependency sprawl, migration risk, and hidden integration work.
- **evaluation**: Emphasize evaluation rigor and observability. Be strict about measurable success criteria, regression detection, and testability.
- **product**: Emphasize product risk and delivery quality. Be strict about user-visible failure modes, sequencing, and scope realism.
- **operations**: Emphasize rollout and operational durability. Be strict about ownership, alerting, rollback, failure handling, and maintenance burden.
- **safety**: Emphasize safety, privacy, and security. Be strict about hallucination controls, citation integrity, access assumptions, and unsafe fallback behavior.

### Step 4 — Report findings

External runners return a JSON object matching `seldon.schema.json` on stdout. Claude then renders it for the user. The schema does **not** include a `Judge` field or a visual confidence bar — those are added by Claude at render time.

Render the result in this exact order:

1. **Judge**: label which runner produced the review (e.g., `inline`, `codex (scripts/codex.sh)`, `anthropic (scripts/anthropic.sh)`, `openai (scripts/openai.sh)`). This is not in the schema — add it from context.
2. **Verdict**: from the schema `verdict` field — one of `approve`, `approve_with_changes`, `request_major_revision`.
3. **Summary**: from the schema `summary` field.
4. **Confidence**: render the numeric `confidence` score from the schema with the visual bar described below.
5. **Strengths**: from the schema `strengths[]` array.
6. **Blocking findings** (if any): from `blocking_findings[]`.
7. **Non-blocking findings** (if any): from `non_blocking_findings[]`.
8. **Open questions** (if any): from `open_questions[]`.

Format each finding with: severity (`critical` / `high` / `medium` / `low`), title, why it matters, evidence from the workspace, and file references (`path:line` when possible).

#### Confidence bar

Render the confidence score as a 20-segment bar using `█` and `░`. Pick the label by score range:

- `0.90–1.00` → `🟢 High confidence`
- `0.70–0.89` → `🟡 Moderate confidence`
- `0.50–0.69` → `🟠 Low confidence`
- `0.00–0.49` → `🔴 Very low confidence`

Example for `0.82` (16 filled, 4 empty):

```
🟡 Confidence  ████████████████░░░░  0.82  (moderate)
```

## Rules

- Judge independently. Do not defer to the plan author or assume good intent where evidence is missing.
- Use blocking findings only for issues that materially threaten the plan. Do not inflate severity.
- If a claim cannot be verified locally (external APIs, time-sensitive data), say so explicitly in evidence rather than pretending it is confirmed.
- If the plan is solid, return empty findings arrays and an `approve` verdict. Do not manufacture issues.
- Do not rewrite the plan unless the user asks for revisions after seeing the judgment.
- Keep the final answer short and factual.

## Bundled Resources

### Schema (`seldon.schema.json`)

JSON Schema (Draft 2020-12) that defines the verdict object the runners return. Fields: `verdict`, `summary`, `confidence` (numeric 0–1), `strengths[]`, `blocking_findings[]`, `non_blocking_findings[]`, `open_questions[]`. Each finding requires `severity`, `title`, `why_it_matters`, `evidence`, `references[]`. All runners embed the schema in the prompt; the model is asked to return matching JSON. Schema conformance is enforced by prompt, not server-side. The `Judge` label and confidence bar are added by Claude at render time and are not part of the schema.

### Scripts (`scripts/`)

External judge runners live next to this `SKILL.md`. Each accepts `--focus <mode> <plan-file> [supporting-files...]` and emits verdict JSON on stdout matching `seldon.schema.json`.

- **`scripts/codex.sh`** — Invokes `codex-companion.mjs task --json` from the Codex plugin. Discovers the companion automatically from `~/.claude/plugins`. Requires the Codex plugin to be installed (`/codex:setup`). Embeds the schema in the prompt; parses the verdict JSON from `rawOutput`. Override model with `JUDGE_MODEL`, reasoning effort with `JUDGE_REASONING` (default `xhigh`).
- **`scripts/anthropic.sh`** — Calls the Anthropic Messages API. Reads `ANTHROPIC_API_KEY`. Default model `claude-sonnet-4-6` (override with `JUDGE_MODEL`).
- **`scripts/openai.sh`** — Calls the OpenAI Chat Completions API with `response_format=json_object`. Reads `OPENAI_API_KEY`. Default model `gpt-4o` (override with `JUDGE_MODEL`).
- **`scripts/validate.sh`** — End-to-end harness: chooses a judge (auto / explicit), runs it, validates the JSON against `seldon.schema.json` using Python's `jsonschema`, and prints a one-line confidence summary. Use it for smoke-testing a runner before relying on its output.

All three judge runners share the same post-processing: detect API-level errors, strip markdown fences, and verify the body parses as JSON before emitting to stdout. They will exit non-zero on any of those failures.

Invoke each script via `bash <skill-dir>/scripts/<name>.sh ...` so file mode does not matter; no `chmod +x` step is required.

### Examples (`examples/`)

- **`examples/demo_plan.md`** — Short, runnable plan suitable for smoke-testing any runner.
- **`examples/sample_verdict.json`** — A schema-conforming verdict, useful as a fixture or when teaching the format.

### Validation tooling (`requirements.txt`)

The runners themselves rely only on `bash`, `curl`, `git`, `python3` (stdlib), and—for the codex runner—the Codex plugin's `codex-companion.mjs`. They do not need any pip packages.

`scripts/validate.sh` does need Python's `jsonschema` package. Install once per checkout in a virtualenv to avoid PEP 668 conflicts on macOS:

```bash
python3 -m venv skills/seldon/.venv
skills/seldon/.venv/bin/pip install -r skills/seldon/requirements.txt
```

Then smoke-test:

```bash
# Auto-detect: codex → ANTHROPIC_API_KEY → OPENAI_API_KEY
bash skills/seldon/scripts/validate.sh skills/seldon/examples/demo_plan.md

# Force a specific judge
bash skills/seldon/scripts/validate.sh --judge codex skills/seldon/examples/demo_plan.md
```

When no judge runner is available, fall back to inline review (Step 2 onward) and skip `validate.sh`.

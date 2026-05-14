# Seldon

> **Independent plan/spec reviewer for AI coding agents — Multi-judge LLM-as-a-Judge with structured verdicts**

<p align="center">
  <em>Analyzes implementation plans the way Hari Seldon analyzed civilizations — by checking structural assumptions against reality before things go wrong.</em>
  <br><br>
  <a href="#install">Install</a> &bull;
  <a href="#usage">Usage</a> &bull;
  <a href="#focus-modes">Focus Modes</a> &bull;
  <a href="#external-judges">External Judges</a> &bull;
  <a href="#output-schema">Output Schema</a>
</p>

<p align="center">
  <img src="https://github.com/degrammer/seldon/blob/main/seldon.png?raw=true" width="150">
</p>

Feed Seldon a plan, spec, or proposal. It reads the document, inspects your workspace for evidence, and returns a verdict — **approve**, **approve_with_changes**, or **request_major_revision** — with a confidence score (0–1) and concrete findings tagged by severity and file references.

Works out of the box as an inline skill for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Plug in [Codex](#codex), [OpenAI](#openai-api), or [Anthropic](#anthropic-api) as an external judge for true model independence — or run all three and compare verdicts side by side.

## Skill

This plugin ships one skill: **Seldon**, with three pluggable judges.

### Seldon (The Reviewer)

*Independent plan/spec reviewer with workspace verification.*

- **Multi-judge LLM-as-a-Judge**: Plug in Anthropic (Claude), OpenAI (GPT), or Codex (via the [Codex plugin](https://github.com/openai/codex-plugin-cc)) — or fall back to inline review using the current agent.
- **Structured Verdicts**: Every response conforms to a strict JSON Schema (`approve`, `approve_with_changes`, `request_major_revision` + confidence + findings).
- **Workspace Verification**: The inline reviewer and codex judge can traverse your codebase to verify claims; the API runners get every file you pass as arguments.
- **Focus Modes**: Six pre-baked weighting profiles — `balanced`, `architecture`, `evaluation`, `product`, `operations`, `safety`.
- **Severity-Tagged Findings**: Each finding lists severity (`critical`/`high`/`medium`/`low`), why it matters, evidence from the workspace, and `path:line` references.
- **Confidence Score**: A numeric 0–1 score from the judge, rendered as a 20-segment visual bar with semantic color labels.
- **Schema-Validated Output**: A bundled `scripts/validate.sh` smoke-test harness checks runner output against `seldon.schema.json` before you trust it.

---

## Quick Start

### Prerequisites

- **Claude Code** (CLI) or **Claude Desktop** — no API keys required for the inline reviewer
- **Optional, per external judge:**
  - `codex` → install the [Codex plugin](https://github.com/openai/codex-plugin-cc) (`/codex:setup`)
  - `anthropic` → export `ANTHROPIC_API_KEY`
  - `openai` → export `OPENAI_API_KEY`
- **For schema validation tooling** (optional): `python3` with `jsonschema` (see [Testing](#testing))

### Installation

#### Option 1: Claude Code Plugin (Recommended)

Install via Claude Code's built-in plugin system:

```bash
# Add the marketplace
/plugin marketplace add proyecto26/seldon

# Install the plugin
/plugin install seldon
```

After installing, the `/seldon` skill triggers automatically on phrases like *"review my plan"*, *"judge this spec"*, *"second opinion on this RFC"*.

#### Option 2: CLI Install via skills.sh

```bash
# Install all skills
npx skills add proyecto26/seldon

# List available skills
npx skills add proyecto26/seldon --list
```

This installs to your `.claude/skills/` directory.

#### Option 3: Clone and Copy

```bash
git clone https://github.com/proyecto26/seldon.git
cp -r seldon/skills/* .claude/skills/
```

#### Option 4: Git Submodule

```bash
git submodule add https://github.com/proyecto26/seldon.git .claude/seldon
```

Reference the skill from `.claude/seldon/skills/seldon/`.

#### Option 5: Fork and Customize

1. Fork this repository
2. Customize `skills/seldon/SKILL.md` for your house style (rubric weights, finding format)
3. Add or modify judge runners in `skills/seldon/scripts/`
4. Clone your fork into your projects

---

## Usage

Trigger phrases that fire the skill:

```
/seldon my-plan.md
review this plan: docs/migration-plan.md
judge this spec: docs/auth-redesign.md
second opinion on RFC-042
```

### What happens

1. Seldon reads your plan file (and any supporting files you pass)
2. Resolves the judge:
   - **`auto`** (default) — probes for codex → `ANTHROPIC_API_KEY` → `OPENAI_API_KEY` → falls back to **inline**
   - **explicit** — say *"judge with codex"* / *"use the openai judge"* / *"use anthropic"*
3. Inspects the workspace to verify claims — file paths, APIs, dependencies, config, schema
4. Evaluates against a rubric: repo fit, correctness, sequencing, evaluation, safety
5. Returns a structured verdict with a visual confidence bar:

```
🟡 Confidence  ████████████████░░░░  0.82  (moderate)
```

### Usage Examples

**"Review my migration plan"**
> Triggers the inline reviewer (or auto-detected external judge) on the file you provide.

**"Judge this RFC with anthropic, focus on safety"**
> Routes to `scripts/anthropic.sh` with `--focus safety`.

**"Get a second opinion from codex on docs/plan.md"**
> Routes to `scripts/codex.sh` via the Codex plugin companion.

**"Run all three judges and compare"**
> Invokes each runner in turn and renders a side-by-side comparison of verdicts and confidence scores.

### Example output

```
Judge: codex (scripts/codex.sh)
Verdict: approve_with_changes

Summary: Plan is sound but assumes a migration path that does not exist yet.

🟡 Confidence  ████████████████░░░░  0.82  (moderate)

Strengths:
- Clear phasing with realistic scope per step
- Good rollback strategy for the data migration

Blocking findings:

  high — Migration depends on schema v3 which hasn't been created
  Why it matters: Step 2 cannot begin without this prerequisite
  Evidence: No v3 migration file exists in prisma/migrations/
  Refs: prisma/schema.prisma:42, docs/plan.md:18

Open questions:
- Is the external billing API rate limit sufficient for the proposed batch size?
```

---

## Focus Modes

Focus modes weight the review toward specific concerns. Default is `balanced`.

| Mode | Emphasis |
|------|----------|
| `balanced` | All rubric dimensions evenly |
| `architecture` | Service boundaries, dependencies, migration risk, hidden integration work |
| `evaluation` | Success criteria, regression detection, testability of quality claims |
| `product` | User-visible failure modes, sequencing, scope realism |
| `operations` | Rollout, alerting, rollback, failure handling, maintenance burden |
| `safety` | Privacy, security, hallucination controls, access assumptions |

```bash
/seldon --focus safety docs/auth-redesign.md
```

---

## External Judges

By default, Seldon runs **inline** — the current agent performs the review using the workspace. To get a model-independent second opinion, plug in one of three external judges. The skill auto-detects which is available.

### Judge Comparison

| Runner | LLM | Workspace access | Required setup |
|--------|-----|------------------|----------------|
| `scripts/codex.sh` | gpt-5.4 (default) via Codex companion | ✅ Read-only sandbox | Install the [Codex plugin](https://github.com/openai/codex-plugin-cc) and run `/codex:setup` |
| `scripts/anthropic.sh` | claude-sonnet-4-6 (default) | ❌ Sees only files passed as args | `export ANTHROPIC_API_KEY=…` |
| `scripts/openai.sh` | gpt-4o (default) | ❌ Sees only files passed as args | `export OPENAI_API_KEY=…` |

### Codex

Routes through the Codex plugin's `codex-companion.mjs` task runner. The Codex agent can read other workspace files to verify claims.

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `JUDGE_MODEL` | `gpt-5.4` | Codex model |
| `JUDGE_REASONING` | `xhigh` | Reasoning effort |

### OpenAI API

Direct call to OpenAI Chat Completions with `response_format=json_object`. Sends plan content in the prompt — only files passed as arguments are visible.

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `JUDGE_MODEL` | `gpt-4o` | Model to use |

### Anthropic API

Direct call to Anthropic Messages. Useful for a second opinion within the Anthropic ecosystem (e.g., judge a Claude Code session with a fresh Claude instance).

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `JUDGE_MODEL` | `claude-sonnet-4-6` | Model to use |

### Writing Your Own Judge

Add a new `scripts/<name>.sh` that:

1. Accepts `[--focus <mode>] <plan-file> [supporting-files...]`
2. Reads `seldon.schema.json` from the skill root (or `scripts/` as fallback)
3. Emits JSON matching that schema on **stdout**
4. Exits non-zero with diagnostics on **stderr** for any failure (auth error, schema not found, malformed model output)

See `scripts/codex.sh` for a fully worked example including markdown-fence stripping and API-level error detection.

---

## Output Schema

Every runner returns JSON conforming to [`skills/seldon/seldon.schema.json`](skills/seldon/seldon.schema.json) (JSON Schema Draft 2020-12):

```json
{
  "verdict": "approve | approve_with_changes | request_major_revision",
  "summary": "1–3 sentence assessment",
  "confidence": 0.82,
  "strengths": ["..."],
  "blocking_findings": [
    {
      "severity": "critical | high | medium | low",
      "title": "Short description of the issue",
      "why_it_matters": "Impact if unaddressed",
      "evidence": "What was found in the workspace",
      "references": ["src/api.ts:42", "docs/plan.md:18"]
    }
  ],
  "non_blocking_findings": [],
  "open_questions": ["Things that couldn't be verified locally"]
}
```

### Confidence ranges

| Range | Label |
|-------|-------|
| 0.90 – 1.00 | 🟢 High confidence |
| 0.70 – 0.89 | 🟡 Moderate confidence |
| 0.50 – 0.69 | 🟠 Low confidence |
| 0.00 – 0.49 | 🔴 Very low confidence |

---

## 📂 Structure

```
seldon/
├── .claude-plugin/
│   ├── plugin.json                # Plugin manifest
│   └── marketplace.json           # Marketplace configuration
└── skills/
    └── seldon/                    # The reviewer skill
        ├── SKILL.md               # Skill instructions (third-person trigger phrases)
        ├── seldon.schema.json     # JSON Schema for verdict objects
        ├── requirements.txt       # Optional: jsonschema for validate.sh
        ├── examples/
        │   ├── demo_plan.md       # Short runnable plan for smoke tests
        │   └── sample_verdict.json # Schema-conforming verdict fixture
        └── scripts/
            ├── codex.sh           # Judge runner: Codex plugin companion
            ├── anthropic.sh       # Judge runner: Anthropic Messages API
            ├── openai.sh          # Judge runner: OpenAI Chat Completions
            └── validate.sh        # E2E harness: run a judge + validate JSON
```

---

## Verifying a runner

To exercise a real LLM round-trip end-to-end and validate the JSON output against the schema:

```bash
# One-time: set up a venv with jsonschema (avoids PEP 668 on macOS)
python3 -m venv skills/seldon/.venv
skills/seldon/.venv/bin/pip install -r skills/seldon/requirements.txt

# Auto-detect: codex → ANTHROPIC_API_KEY → OPENAI_API_KEY
bash skills/seldon/scripts/validate.sh skills/seldon/examples/demo_plan.md

# Force a specific judge
bash skills/seldon/scripts/validate.sh --judge codex     skills/seldon/examples/demo_plan.md
bash skills/seldon/scripts/validate.sh --judge anthropic skills/seldon/examples/demo_plan.md
bash skills/seldon/scripts/validate.sh --judge openai    skills/seldon/examples/demo_plan.md
```

Each invocation prints a one-line verdict + confidence summary, then the full JSON if validation passed.

---

## Compatibility

Seldon works with any agent that supports `SKILL.md` skills:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (recommended — full plugin support)
- [Claude Desktop](https://claude.ai/download) via Cowork plugin installation
- [Gemini CLI](https://github.com/google-gemini/gemini-cli)
- Any agent supporting the skills.sh ecosystem

---

## Name

Named after [Hari Seldon](https://en.wikipedia.org/wiki/Hari_Seldon) from Isaac Asimov's *Foundation* series. Seldon developed psychohistory — a science that predicted the future of civilizations by analyzing structural assumptions against reality. At critical decision points, a holographic Seldon would appear and say:

> *"If you're seeing this, here's what you got wrong."*

That's what `/seldon` does for your implementation plans.

---

## 🌟 Star History

[![Star History Chart](https://api.star-history.com/svg?repos=proyecto26/seldon&type=Date)](https://star-history.com/#proyecto26/seldon&Date)

## 💜 Sponsors

This project is free and open source. Sponsors help keep it maintained and growing.

[**Become a Sponsor**](https://github.com/sponsors/proyecto26) | [Sponsorship Program](https://proyecto26.com/sponsors/)

## 🤝 Contribution

When contributing to this repository, please first discuss the change you wish to make via issue,
email, or any other method with the owners of this repository before making a change.

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated** ❤️.

You can learn more about how you can contribute to this project in the [contribution guide](https://github.com/proyecto26/.github/blob/master/CONTRIBUTING.md).

## 👍 Credits

- Originally authored by [@degrammer](https://github.com/degrammer) — the Hari Seldon analogy and the core inline-review concept.
- Inspired by the broader [LLM-as-a-Judge](https://arxiv.org/abs/2306.05685) research line.

## Happy vibe reviewing 💯
Made with ❤️ by [Proyecto 26](https://proyecto26.com) - Changing the world with small contributions.

One hand can accomplish great things, but many can take you into space and beyond! 🌌

Together we do more, together we are more ❤️ <img width="150px" src="https://avatars0.githubusercontent.com/u/28855608?s=200&v=4" align="right">

## License

MIT — see [LICENSE](LICENSE)

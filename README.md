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

Works out of the box as an inline skill in **Claude Code, OpenAI Codex, Cursor, and GitHub Copilot CLI** — packaged as an [Agent Plugins 1.0](https://agent-plugins.org/) plugin plus native manifests for each host. Plug in [Codex](#codex), [OpenAI](#openai-api), or [Anthropic](#anthropic-api) as an external judge for true model independence — or run all three and compare verdicts side by side.

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

- One supported host: **Claude Code**, **OpenAI Codex**, **Cursor**, or **GitHub Copilot CLI** — no API keys required for the inline reviewer
- **Optional, per external judge:**
  - `codex` → the [`codex` CLI](https://github.com/openai/codex) on PATH (`npm i -g @openai/codex`), or in Claude Code the [Codex plugin](https://github.com/openai/codex-plugin-cc) (`/codex:setup`)
  - `anthropic` → export `ANTHROPIC_API_KEY`
  - `openai` → export `OPENAI_API_KEY`
- **For schema validation tooling** (optional): `python3` with `jsonschema` (see [Testing](#testing))

### Installation

#### Option 1: Install as a plugin (Recommended)

Pick your host. Each one reads its own manifest from this repo, so the same `proyecto26/seldon` source works everywhere.

| Host | Install |
|------|---------|
| **Claude Code** | `/plugin marketplace add proyecto26/seldon` then `/plugin install seldon` |
| **OpenAI Codex** | `codex plugin marketplace add proyecto26/seldon` then open `/plugins` in Codex and install **Seldon** |
| **GitHub Copilot CLI** | `copilot plugin marketplace add proyecto26/seldon` then `copilot plugin install seldon@seldon-marketplace` |
| **Cursor** | Settings → Plugins → install from Git URL `https://github.com/proyecto26/seldon` (Agent Plugins format is detected from the root `plugin.json`) |

After installing, the `seldon` skill triggers automatically on phrases like *"review my plan"*, *"judge this spec"*, *"second opinion on this RFC"* (in Claude Code it is also available as `/seldon`).

<details>
<summary>How the multi-host packaging works</summary>

- `plugin.json` (repo root) — the portable [Agent Plugins 1.0](https://agent-plugins.org/specification) manifest. Cursor and Copilot CLI read this directly and discover `skills/` automatically.
- `.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json` — OpenAI Codex manifest and marketplace catalog.
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — Claude Code manifest and marketplace catalog (Copilot CLI also reads this marketplace file).
- `scripts/check-manifests.sh` asserts that `name`, `version` and `description` stay identical across all of them.

</details>

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
| `scripts/codex.sh` | Codex default model (e.g. gpt-5.5) | ✅ Read-only sandbox | `codex` CLI on PATH, **or** in Claude Code the [Codex plugin](https://github.com/openai/codex-plugin-cc) (`/codex:setup`) |
| `scripts/anthropic.sh` | claude-sonnet-4-6 (default) | ❌ Sees only files passed as args | `export ANTHROPIC_API_KEY=…` |
| `scripts/openai.sh` | gpt-4o (default) | ❌ Sees only files passed as args | `export OPENAI_API_KEY=…` |

### Codex

Runs a read-only Codex agent rooted at your git workspace, so it can read other files to verify claims. Two backends, auto-selected:

- **`cli`** (preferred, works in every host) — `codex exec --sandbox read-only --output-schema seldon.schema.json`. Selected only if the `codex` on PATH advertises every flag the runner needs; otherwise auto mode falls back to the companion.
- **`companion`** (Claude Code only) — `codex-companion.mjs` from the Codex plugin for Claude Code. Auto mode uses it only inside a Claude Code session; elsewhere set `SELDON_CODEX_BACKEND=companion` explicitly, because it runs with that Claude Code installation's configuration and credentials.

Either way the runner validates the verdict against `seldon.schema.json` before printing it.

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `JUDGE_MODEL` | Codex default | Codex model |
| `JUDGE_REASONING` | `xhigh` | Reasoning effort |
| `SELDON_CODEX_BACKEND` | auto | Force `cli` or `companion` |

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
├── plugin.json                    # Agent Plugins 1.0 manifest (Cursor, Copilot CLI)
├── .codex-plugin/
│   └── plugin.json                # OpenAI Codex manifest
├── .agents/plugins/
│   └── marketplace.json           # OpenAI Codex marketplace catalog
├── .claude-plugin/
│   ├── plugin.json                # Claude Code manifest
│   └── marketplace.json           # Claude Code / Copilot CLI marketplace catalog
├── scripts/
│   └── check-manifests.sh         # Asserts all manifests agree on name/version/description
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
skills/seldon/.venv/bin/pip install -r skills/seldon/requirements.txt   # Windows: .venv/Scripts/pip

# Release gate: manifests agree on name/version/description and install wiring, and the
# host validators that exist (claude plugin validate, Agent Plugins schema) pass.
# Fails closed if a validator cannot run; add --allow-skips for local convenience.
bash scripts/check-manifests.sh

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

Seldon is packaged as an [Agent Plugins 1.0](https://agent-plugins.org/) plugin and ships native manifests for:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `.claude-plugin/`
- [OpenAI Codex](https://developers.openai.com/codex) — `.codex-plugin/` + `.agents/plugins/`
- [Cursor](https://cursor.com/docs/plugins) — root `plugin.json`
- [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli/customize-copilot/plugins-creating) — root `plugin.json`

It also works with any agent that supports `SKILL.md` skills: [Claude Desktop](https://claude.ai/download) (Cowork), [Gemini CLI](https://github.com/google-gemini/gemini-cli), and the skills.sh ecosystem.

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

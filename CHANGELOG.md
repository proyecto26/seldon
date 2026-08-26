# Changelog

## 1.1.0 — 2026-08-25

### Added
- **Multi-host packaging.** Seldon now installs in Claude Code, OpenAI Codex, Cursor, and GitHub Copilot CLI from the same repository:
  - `plugin.json` (repo root) — [Agent Plugins 1.0](https://agent-plugins.org/specification) portable manifest, read by Cursor and Copilot CLI.
  - `.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json` — OpenAI Codex manifest and marketplace catalog.
  - Existing `.claude-plugin/` files are unchanged apart from the version bump.
- `scripts/check-manifests.sh` — release gate. Fails if `name`, `version` or `description` differ across the host manifests, if `plugin.json` contains fields outside the Agent Plugins 1.0 closed schema, or if the install wiring drifts (Codex marketplace `source`/`path`/`policy`, Claude marketplace `source`/`skills`/`strict`, `.codex-plugin` required fields, `skills/seldon/SKILL.md` present).
- `CHANGELOG.md` (this file).

### Changed
- `skills/seldon/scripts/codex.sh` now works outside Claude Code. It prefers the `codex` CLI on PATH — after probing `codex exec --help` for every flag it needs, so an old or unrelated `codex` binary is never selected — and, only inside a Claude Code session (`CLAUDECODE` set), falls back to `codex-companion.mjs` from the Codex plugin for Claude Code. Outside Claude Code the companion must be requested explicitly with `SELDON_CODEX_BACKEND=companion`, since it runs with that installation's configuration and credentials. The chosen backend and version are logged to stderr; `codex.sh --probe` reports backend availability without running a review.
- `codex.sh` validates the verdict against `seldon.schema.json` for **both** backends before printing (with `jsonschema` when installed, otherwise a built-in checker), so schema-invalid output exits non-zero instead of reaching the caller.
- `skills/seldon/scripts/validate.sh` auto mode now treats every available judge as a candidate (codex via `codex.sh --probe` → anthropic → openai); a candidate counts as successful only if it exits 0 **and** its output validates against `seldon.schema.json`, otherwise the next candidate runs. It fails only when all candidates fail (previously a Codex failure was terminal even with API keys present). Also finds the skill venv on Windows (`.venv/Scripts/python.exe`) as well as POSIX, and prints its summary correctly on non-UTF-8 consoles.
- `scripts/check-manifests.sh` also runs the host validators that exist — `claude plugin validate` and the Agent Plugins 1.0.0 JSON schema — and fails closed if either cannot run (`--allow-skips` tolerates that locally). Codex and Copilot publish no validator, so those manifests get structural checks plus the install runs recorded below.
- SKILL.md frontmatter description shortened to trigger phrases; runner-scope note moved into the body. Step 1 documents both Codex backends.
- README: per-host install matrix, updated structure tree and compatibility section.

### Validated on (2026-08-25, Windows 11, this release's working tree)

| Host | Check | Result |
|------|-------|--------|
| Claude Code | `claude plugin validate .` | ✅ passed |
| Agent Plugins 1.0 | `plugin.json` validated against `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json` (python `jsonschema`) | ✅ no errors |
| Manifest consistency | `bash scripts/check-manifests.sh` | ✅ consistent |
| GitHub Copilot CLI 1.0.80 | `copilot plugin install <clean export>` and `copilot plugin marketplace add … && copilot plugin install seldon@seldon-marketplace` | ✅ `seldon (v1.1.0)`, 1 skill installed |
| OpenAI Codex CLI 0.130.0 | `codex plugin marketplace add ./` | ✅ marketplace `seldon-marketplace` registered; manifest and catalog format cross-checked against OpenAI's bundled `openai-bundled` marketplace on disk. Install via the interactive `/plugins` picker **not exercised** (no non-interactive install command in 0.130). |
| Codex judge, `cli` backend | `SELDON_CODEX_BACKEND=cli bash skills/seldon/scripts/validate.sh --judge codex examples/demo_plan.md` | ✅ schema-valid verdict (confidence 0.86) |
| Codex judge, `companion` backend | `SELDON_CODEX_BACKEND=companion bash … --judge codex …` | ✅ schema-valid verdict (confidence 0.86) |
| `codex.sh` behaviour | shim `codex` binaries on PATH: compatible → verdict emitted; schema-invalid output → exit 1, empty stdout; incompatible CLI in auto → companion fallback only when `CLAUDECODE` is set, otherwise exit 1; forced `cli` → exit 1; explicit `companion` works outside Claude Code | ✅ |
| `validate.sh` auto mode | CLI that probes fine but fails at `exec` + `OPENAI_API_KEY` → moves on to `openai`; runner that exits 0 with schema-invalid JSON → its `FAIL` goes to stderr and the next candidate runs; no keys → "All candidate judges failed"; stdout on success is exactly the summary line + raw JSON | ✅ |
| `check-manifests.sh` gate | `claude` absent → exit 1; `--allow-skips` → exit 0 with `SKIP` + trailing "NOT release evidence" warning; `--allow-skips` with `CI` set → exit 1 | ✅ |
| `check-manifests.sh` | tampered copy (drifted version, Codex `source.path`, component field in `.claude-plugin/plugin.json`) | ✅ fails as expected |
| Cursor CLI 2026.08.11 | `agent --plugin-dir <export>` and `~/.cursor/settings.json` `enabled_plugins` in `--print --mode ask` | ⚠️ **inconclusive** — the headless agent's skill list was truncated (146 shown of 360 on this machine), so the `seldon` skill could not be confirmed or ruled out; the same held for a `.cursor-plugin/plugin.json` diagnostic variant. Not counted as verified. Verify via the Cursor IDE (Settings → Plugins) or `agent plugin marketplace add https://github.com/proyecto26/seldon` once this release is pushed. Relies on Cursor's documented support for root `plugin.json` Agent Plugins. |

Note for Copilot CLI: installing from a working tree that contains `.git/` or a `.venv/` can fail with *access denied* while Copilot copies the directory; install from a clean checkout or from the marketplace.

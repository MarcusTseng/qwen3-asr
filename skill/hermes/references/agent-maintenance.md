# Agent Maintenance Notes

Use these notes when a future Claude/Hermes/OpenClaw agent improves the Qwen3-ASR integration.

## Canonical location

All changes (scripts AND skill metadata) go to the **standalone repo**: `~/projects/qwen3-asr/`  
GitHub: https://github.com/MarcusTseng/qwen3-asr

```
skill/
  claude/   ← cc-switch / Claude skill format (SKILL.md, DESCRIPTION.md, _meta.json)
  hermes/   ← Hermes skill format (SKILL.md, references/)
scripts/    ← shared across all agents
```

External symlinks point into the repo — a `git pull` syncs everything:

```
~/.cc-switch/skills/qwen3-asr/SKILL.md        → skill/claude/SKILL.md
~/.cc-switch/skills/qwen3-asr/DESCRIPTION.md  → skill/claude/DESCRIPTION.md
~/.hermes/skills/media/qwen3-asr/SKILL.md     → skill/hermes/SKILL.md
~/.hermes/skills/media/qwen3-asr/references/  → skill/hermes/references/
```

## Verification contract

Before reporting success after changes, run both:

```bash
qwen3-asr-status
~/projects/qwen3-asr/tests/smoke.sh
```

Smoke test expected output must include `ask not what your country can do for you`.  
Smoke test exit code must be 0.

## Workflow after edits

```bash
cd ~/projects/qwen3-asr
git add -p
git commit -m "..."
git push
# symlinks mean no further sync needed — both agents see changes immediately
```

Regenerate Hermes distributable package after skill metadata changes:

```bash
cd /home/marcus/.hermes/skills/skill-creator
PYTHONPATH=/home/marcus/.hermes/skills/skill-creator \
  /home/linuxbrew/.linuxbrew/bin/python3 scripts/package_skill.py \
  /home/marcus/.hermes/skills/media/qwen3-asr \
  /home/marcus/.hermes/packages
```

## Key design decisions (do not break these)

1. `qwen3-asr-transcribe` is the stable user-facing command — never rename it.
2. Stdout = transcript only; stderr = diagnostics. Callers pipe stdout.
3. All paths are env-var-driven via `.env`. No hardcoded `/home/...` in committed files.
4. Whisper fallback = HTTP POST to `WHISPER_SERVER_URL` — not a local script.
5. `set -euo pipefail` is active — avoid patterns that silently swallow errors:
   - Use `|| true` when a command is allowed to fail before checking output.
   - Use `if/fi` instead of `[[ cond ]] && cmd` in EXIT traps.
   - `$(_mktmp)` runs in a subshell — use a temp directory (`_TMPDIR`), not an array.
6. Always use `readlink -f "${BASH_SOURCE[0]}"` to resolve `SCRIPT_DIR` — plain `dirname` breaks when called through a symlink.

## Pitfalls (from past sessions)

- `mktemp -u` is a TOCTOU vulnerability — use `mktemp -d`.
- `--suffix=.wav` in `mktemp` is GNU-only — use `mktemp /tmp/name.XXXXXX.wav`.
- `~` does not expand inside double-quoted strings — use `$HOME`.
- JSON fields built with `printf` are injectable — use `python3 json.dumps()` for all fields.
- CrispASR invocation must be `|| true`-guarded so the log can be read on failure.
- `${BASH_SOURCE[0]}` returns the symlink path, not the real file — use `readlink -f`.

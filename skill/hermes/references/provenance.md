# Qwen3-ASR Provenance and Layout

## Canonical source

**GitHub:** https://github.com/MarcusTseng/qwen3-asr  
**Local clone:** `~/projects/qwen3-asr/`

## Origin

Originally created as an OpenClaw skill wrapping Qwen3-ASR (QwenLM/Qwen3-ASR, released Jan 2026).
Reorganised into a standalone repo (May 2026) to remove all OpenClaw/Hermes path dependencies
and make the code shippable as a public GitHub repo.

## Repo layout

```
scripts/              ← shared across all agents (real files)
skill/
  claude/             ← cc-switch / Claude skill format
    SKILL.md
    DESCRIPTION.md
    _meta.json
  hermes/             ← Hermes skill format
    SKILL.md
    references/
      agent-maintenance.md
      provenance.md   ← this file
setup/
tests/
.env.example
requirements.txt
README.md
```

## External symlink map

```
~/.cc-switch/skills/qwen3-asr/SKILL.md            → skill/claude/SKILL.md
~/.cc-switch/skills/qwen3-asr/DESCRIPTION.md      → skill/claude/DESCRIPTION.md
~/.cc-switch/skills/qwen3-asr/scripts/            → scripts/ (individual symlinks)
~/.cc-switch/skills/qwen3-asr/repo                → ~/projects/qwen3-asr

~/.claude/skills/qwen3-asr                        → ~/.cc-switch/skills/qwen3-asr

~/.hermes/skills/media/qwen3-asr/SKILL.md         → skill/hermes/SKILL.md
~/.hermes/skills/media/qwen3-asr/references/      → skill/hermes/references/ (individual symlinks)
~/.hermes/skills/media/qwen3-asr/scripts/         → scripts/ (individual symlinks)

~/.local/bin/qwen3-asr-transcribe                 → scripts/transcribe.sh
~/.local/bin/qwen3-asr-status                     → scripts/status.sh
```

## Runtime assets (not in repo)

- CrispASR binary: `QWEN3_ASR_CRISP_BIN` in `.env`
- GGUF model: `QWEN3_ASR_CRISP_MODEL` in `.env`
- PyTorch venv: `venv/` (created by `setup/setup_venv.sh`)
- Whisper fallback: whisper-server at `http://localhost:8082/` (systemd user service)

## Upstream model

- Qwen3-ASR-1.7B / 0.6B — 52 languages, 22 Chinese dialects
- Qwen3-ForcedAligner-0.6B — timestamp alignment (not yet exposed in wrapper)

## Improvement targets

- `--timestamps` flag via Qwen3-ForcedAligner
- vLLM backend for batch/streaming
- Regression sample under `assets/jfk.wav` if licensing permits

## What NOT to do

- Do not bundle model weights or virtualenvs in the repo
- Do not hardcode `/home/...` paths in committed files
- Do not edit skill files in `~/.cc-switch/` or `~/.hermes/` directly — edit in repo and push

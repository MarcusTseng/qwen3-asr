---
name: qwen3-asr
description: Local Qwen3-ASR speech-to-text wrapper for StrixHalo and Claude/Hermes agents. Use this whenever an agent needs to transcribe audio, voice notes, Discord/Telegram voice files, podcasts, Mandarin/Cantonese/Chinese-dialect speech, multilingual speech, or when comparing/replacing mcp-whisper/local-whisper. Provides one low-friction command that prefers the CrispASR/Vulkan runtime and falls back to the whisper-server HTTP endpoint.
metadata:
  created_by: agent
  version: 2.0.0
---

# Qwen3-ASR Local STT

Standalone repo: **https://github.com/MarcusTseng/qwen3-asr**  
Local clone: `~/projects/qwen3-asr/`

## One command

```bash
qwen3-asr-transcribe /path/to/audio.ogg
```

Or directly:

```bash
~/projects/qwen3-asr/scripts/transcribe.sh /path/to/audio.ogg
```

Transcript on stdout, diagnostics on stderr.

## Options

```
--backend  auto|crisp|torch|whisper   (default: auto)
--language <lang>                     e.g. zh, en, yue — default: auto-detect
--output   text|json                  (default: text)
```

JSON output: `{"text":"...","language":"zh","backend":"crisp","elapsed_ms":1420}`

## Backend order (auto mode)

1. **CrispASR / Vulkan / GGUF** — fastest; requires binary + GGUF model configured in `.env`
2. **PyTorch / transformers** — CPU fallback; requires `venv/`
3. **whisper-server HTTP** — POST to `http://localhost:8082/v1/audio/transcriptions`

Force a backend:

```bash
qwen3-asr-transcribe --backend crisp   audio.wav
qwen3-asr-transcribe --backend torch   audio.wav
qwen3-asr-transcribe --backend whisper audio.wav
```

## Runtime configuration

Paths are env-var-driven. Edit `~/projects/qwen3-asr/.env` (gitignored):

```bash
QWEN3_ASR_CRISP_BIN=/path/to/CrispASR/build-vulkan/bin/crispasr
QWEN3_ASR_CRISP_MODEL=/path/to/models/qwen3-asr-1.7b-q8_0.gguf
WHISPER_SERVER_URL=http://localhost:8082/v1/audio/transcriptions
```

## Validate before claiming success

```bash
qwen3-asr-status
~/projects/qwen3-asr/tests/smoke.sh
```

Expected: `ask not what your country can do for you`

## Output policy

- Chinese / Cantonese → Traditional Chinese (opencc `s2t`)
- English → English
- Other detected language → English via whisper-server fallback

## When improving this skill

Read `references/agent-maintenance.md`.  
All changes go to `~/projects/qwen3-asr/` — commit and push to GitHub.  
Skill metadata lives in `skill/hermes/` inside the repo; symlinks update automatically on `git pull`.

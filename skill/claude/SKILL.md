---
name: qwen3-asr
description: Local Qwen3-ASR speech-to-text for StrixHalo. Use when transcribing audio, voice notes, Discord/Telegram voice files, podcasts, or Mandarin/Cantonese/Chinese-dialect speech. Prefers CrispASR Vulkan/GGUF (fastest), falls back to PyTorch transformers, then whisper-server HTTP. Supports 52 languages and 22 Chinese dialects. Prefer this over local-whisper for Chinese audio.
---

# Qwen3-ASR

**Repo:** https://github.com/MarcusTseng/qwen3-asr  
**Local:** `~/projects/qwen3-asr/`

## Run

```bash
qwen3-asr-transcribe /path/to/audio.ogg
```

Or directly:

```bash
~/projects/qwen3-asr/scripts/transcribe.sh /path/to/audio.ogg
```

## Options

```
--backend  auto|crisp|torch|whisper   (default: auto)
--language zh|en|yue|ja|...          language hint (default: auto-detect)
--output   text|json                  (default: text)
```

JSON output: `{"text":"...","language":"zh","backend":"crisp","elapsed_ms":1420}`

## Backend order (auto)

1. **CrispASR** — Vulkan/GGUF, fastest, requires `.env` config
2. **torch** — PyTorch/transformers CPU, requires `venv/`
3. **whisper** — HTTP POST to `localhost:8082/v1/audio/transcriptions`

## Configure

```bash
cd ~/projects/qwen3-asr
cp .env.example .env   # edit QWEN3_ASR_CRISP_BIN, QWEN3_ASR_CRISP_MODEL
./setup/setup_venv.sh  # PyTorch backend deps
```

## Output policy

- Chinese / Cantonese → Traditional Chinese (opencc s2t)
- English → English
- Other language → English via whisper-server fallback

## Validate

```bash
qwen3-asr-status
~/projects/qwen3-asr/tests/smoke.sh
```

Expected: `ask not what your country can do for you`

## Troubleshooting

- CrispASR MISS: set `QWEN3_ASR_CRISP_BIN` and `QWEN3_ASR_CRISP_MODEL` in `.env`
- torch MISS: run `./setup/setup_venv.sh`
- whisper MISS: `systemctl --user start whisper-server`

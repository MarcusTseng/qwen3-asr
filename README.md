# qwen3-asr

Local speech-to-text wrapper for [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) (1.7B / 0.6B).  
Supports 52 languages and 22 Chinese dialects. Runs fully offline on AMD/Vulkan hardware.

Built around three tiers:

| Backend | Runtime | Speed |
|---|---|---|
| **crisp** | CrispASR + GGUF + Vulkan | Fastest (GPU-accelerated) |
| **torch** | PyTorch / HuggingFace transformers | CPU fallback |
| **whisper** | whisper-server HTTP (localhost:8082) | Final fallback |

---

## Quick start

```bash
git clone https://github.com/MarcusTseng/qwen3-asr
cd qwen3-asr
cp .env.example .env      # edit paths to match your system
./setup/setup_venv.sh     # create venv + install qwen-asr, opencc, requests
./scripts/status.sh       # check all backends
./scripts/transcribe.sh /path/to/audio.ogg
```

---

## Installation

### 1. Python dependencies (PyTorch backend)

```bash
./setup/setup_venv.sh
```

Installs `qwen-asr`, `opencc-python-reimplemented`, and `requests` into `./venv/`.

### 2. CrispASR binary + GGUF model (optional, fastest path)

Build CrispASR with Vulkan support and download the quantized model:

```
QWEN3_ASR_CRISP_BIN=/path/to/bin/crispasr
QWEN3_ASR_CRISP_MODEL=/path/to/models/qwen3-asr-1.7b-q8_0.gguf
```

Set these in `.env` or your shell. The crisp backend is skipped gracefully if unavailable.

### 3. Whisper-server (fallback)

The fallback uses an OpenAI-compatible whisper endpoint:

```
WHISPER_SERVER_URL=http://localhost:8082/v1/audio/transcriptions
```

Compatible with [whisper.cpp server](https://github.com/ggerganov/whisper.cpp), faster-whisper-server, and any OpenAI `/v1/audio/transcriptions` implementation.

---

## Usage

```
scripts/transcribe.sh [OPTIONS] <audio_file>

Options:
  --backend  auto|crisp|torch|whisper   (default: auto)
  --language <lang>                     language hint: zh, en, yue, ja, ...
  --output   text|json                  (default: text)
  -h, --help
```

### Examples

```bash
# Auto backend (crisp → torch → whisper)
./scripts/transcribe.sh meeting.ogg

# Force CrispASR, Cantonese
./scripts/transcribe.sh --backend crisp --language yue lecture.wav

# Structured JSON output
./scripts/transcribe.sh --output json podcast.mp3

# Force whisper fallback only
./scripts/transcribe.sh --backend whisper recording.m4a
```

### JSON output format

```json
{"text": "transcript here", "language": "zh", "backend": "crisp", "elapsed_ms": 1420}
```

---

## Configuration

Copy `.env.example` to `.env` and edit as needed:

```bash
cp .env.example .env
```

All settings are also overridable via environment variable without a `.env` file.

| Variable | Default | Description |
|---|---|---|
| `QWEN3_ASR_CRISP_BIN` | `./bin/crispasr` | CrispASR binary path |
| `QWEN3_ASR_CRISP_MODEL` | `./models/qwen3-asr-1.7b-q8_0.gguf` | GGUF model path |
| `QWEN3_ASR_VENV` | `./venv` | Python venv directory |
| `WHISPER_SERVER_URL` | `http://localhost:8082/v1/audio/transcriptions` | Whisper fallback endpoint |
| `QWEN3_ASR_LANGUAGE` | *(auto-detect)* | Language hint for all backends |
| `QWEN3_ASR_TRADITIONAL` | `1` | Convert Simplified → Traditional Chinese |
| `QWEN3_ASR_BACKEND` | `auto` | Override default backend |

---

## Status check

```bash
./scripts/status.sh
```

Reports OK / MISS for each backend component and the whisper-server reachability.

---

## Testing

```bash
./tests/smoke.sh
# or with a custom sample:
./tests/smoke.sh /path/to/audio.wav
```

Runs CrispASR, whisper fallback, and auto-chain against a known-good sample and validates the output.

---

## Output rules

- **Chinese** (zh / yue / Cantonese) → Traditional Chinese via opencc `s2t`
- **English** → English
- **Other detected language** → English via whisper-server fallback
- `stdout` is transcript only; all diagnostics go to `stderr` — safe to pipe/capture

---

## Repo layout

```
scripts/
  transcribe.sh          ← stable entrypoint (auto backend selection)
  transcribe_crispasr.sh ← Vulkan/GGUF path
  transcribe_local.sh    ← PyTorch/transformers path
  transcribe.py          ← Python inference worker
  status.sh              ← runtime health check
setup/
  setup_venv.sh          ← one-command Python env setup
tests/
  smoke.sh               ← regression test
.env.example             ← configuration reference
requirements.txt         ← Python dependencies
```

Model weights and virtualenvs are **not** included in this repo. Configure paths via `.env`.

---

## Credits

- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) by Alibaba / Qwen Team — the underlying model and `qwen-asr` package
- [CrispASR](https://github.com/thebarslan/crispasr) — GGUF inference runtime with Vulkan support
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — whisper-server fallback

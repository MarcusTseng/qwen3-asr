#!/usr/bin/env bash
# transcribe_crispasr.sh — Qwen3-ASR via CrispASR + Vulkan + GGUF.
# Stdout: transcript text only. Stderr: diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

INPUT_FILE="${1:-}"
MODEL_PATH="${QWEN3_ASR_CRISP_MODEL:-$REPO_DIR/models/qwen3-asr-1.7b-q8_0.gguf}"
CRISP_BIN="${QWEN3_ASR_CRISP_BIN:-$REPO_DIR/bin/crispasr}"
QWEN_VENV_PY="${QWEN3_ASR_VENV_PY:-${QWEN3_ASR_VENV:-$REPO_DIR/venv}/bin/python}"
LANGUAGE="${QWEN3_ASR_LANGUAGE:-zh}"
GPU_BACKEND="${QWEN3_ASR_GPU_BACKEND:-vulkan}"
DEVICE="${QWEN3_ASR_DEVICE:-0}"
THREADS="${QWEN3_ASR_THREADS:-4}"
CONVERT_TRADITIONAL="${QWEN3_ASR_TRADITIONAL:-1}"
BEST_OF="${QWEN3_ASR_BEST_OF:-2}"
BEAM_SIZE="${QWEN3_ASR_BEAM_SIZE:-2}"
MAX_NEW_TOKENS="${QWEN3_ASR_MAX_NEW_TOKENS:-384}"
NO_FALLBACK="${QWEN3_ASR_NO_FALLBACK:-1}"

if [[ -z "$INPUT_FILE" ]]; then
  echo "Usage: $0 <audio_file>" >&2; exit 1
fi
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: input file not found: $INPUT_FILE" >&2; exit 1
fi
if [[ ! -x "$CRISP_BIN" ]]; then
  echo "Error: crispasr binary not found/executable: $CRISP_BIN" >&2; exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Error: model not found: $MODEL_PATH" >&2; exit 1
fi

# Use a secure temp directory (not mktemp -u) to avoid TOCTOU symlink attacks
TMP_DIR="$(mktemp -d /tmp/qwen3-asr-crisp.XXXXXX)"
TMP_BASE="$TMP_DIR/output"
TMP_WAV="$TMP_DIR/input.wav"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Normalize to 16kHz mono WAV (parity with PyTorch path; CrispASR handles WAV natively)
if ! ffmpeg -y -i "$INPUT_FILE" -ar 16000 -ac 1 "$TMP_WAV" >/dev/null 2>&1; then
  echo "Error: ffmpeg failed to normalize input audio" >&2; exit 1
fi

EXTRA_ARGS=(
  --backend qwen3
  --gpu-backend "$GPU_BACKEND"
  -dev "$DEVICE"
  -t "$THREADS"
  -bo "$BEST_OF"
  -bs "$BEAM_SIZE"
  -n "$MAX_NEW_TOKENS"
  -m "$MODEL_PATH"
  -f "$TMP_WAV"
  -l "$LANGUAGE"
  -otxt
  -of "$TMP_BASE"
)
[[ "$NO_FALLBACK" == "1" ]] && EXTRA_ARGS+=( -nf )

# Allow crispasr to fail non-zero so we can report the log before exiting
"$CRISP_BIN" "${EXTRA_ARGS[@]}" > "${TMP_BASE}.log" 2>&1 || true

if [[ ! -s "${TMP_BASE}.txt" ]]; then
  echo "Error: CrispASR produced no transcript. Log:" >&2
  cat "${TMP_BASE}.log" >&2 || true
  exit 1
fi

if [[ "$CONVERT_TRADITIONAL" == "1" && -x "$QWEN_VENV_PY" ]]; then
  "$QWEN_VENV_PY" -c '
import sys
text = sys.stdin.read()
try:
    from opencc import OpenCC
    print(OpenCC("s2t").convert(text), end="")
except Exception:
    print(text, end="")
' < "${TMP_BASE}.txt"
else
  cat "${TMP_BASE}.txt"
fi

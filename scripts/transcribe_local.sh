#!/usr/bin/env bash
# transcribe_local.sh — Qwen3-ASR PyTorch/transformers backend.
# On failure falls back to whisper-server HTTP.
# Stdout: transcript text only. Stderr: diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

INPUT_FILE="${1:-}"
VENV_DIR="${QWEN3_ASR_VENV:-$REPO_DIR/venv}"
PY_SCRIPT="$SCRIPT_DIR/transcribe.py"
WHISPER_URL="${WHISPER_SERVER_URL:-http://localhost:8082/v1/audio/transcriptions}"

if [[ -z "$INPUT_FILE" ]]; then
  echo "Usage: $0 <audio_file>" >&2; exit 1
fi
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: input file '$INPUT_FILE' not found." >&2; exit 1
fi

TEMP_WAV="$(mktemp --suffix=.wav)"
cleanup() { rm -f "$TEMP_WAV"; }
trap cleanup EXIT

ffmpeg -y -i "$INPUT_FILE" -ar 16000 -ac 1 "$TEMP_WAV" >/dev/null 2>&1

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

if python "$PY_SCRIPT" "$TEMP_WAV"; then
  exit 0
fi

echo "qwen3-asr (torch): Python transcription failed; falling back to whisper-server" >&2

if ! curl -sf --max-time 5 "$WHISPER_URL" -o /dev/null 2>/dev/null; then
  echo "Error: whisper-server not reachable at $WHISPER_URL" >&2
  exit 1
fi

curl -sS --max-time 300 -X POST "$WHISPER_URL" \
  -F "file=@$INPUT_FILE" \
  -F "model=whisper-1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','').strip())"

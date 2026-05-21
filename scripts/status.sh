#!/usr/bin/env bash
# status.sh — check runtime readiness for qwen3-asr backends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

CRISP_BIN="${QWEN3_ASR_CRISP_BIN:-$REPO_DIR/bin/crispasr}"
CRISP_MODEL="${QWEN3_ASR_CRISP_MODEL:-$REPO_DIR/models/qwen3-asr-1.7b-q8_0.gguf}"
VENV_PY="${QWEN3_ASR_VENV:-$REPO_DIR/venv}/bin/python"
WHISPER_URL="${WHISPER_SERVER_URL:-http://localhost:8082/v1/audio/transcriptions}"

check_executable() {
  local label="$1" path="$2"
  if [[ -x "$path" ]]; then
    printf 'OK   %-30s %s\n' "$label" "$path"
  else
    printf 'MISS %-30s %s (not executable/found)\n' "$label" "$path"
  fi
}

check_file() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    printf 'OK   %-30s %s\n' "$label" "$path"
  else
    printf 'MISS %-30s %s (not found)\n' "$label" "$path"
  fi
}

echo "=== Qwen3-ASR backend status ==="
echo

echo "--- CrispASR (Vulkan/GGUF) ---"
check_executable "crispasr binary"        "$CRISP_BIN"
check_file       "GGUF model"             "$CRISP_MODEL"
check_executable "scripts/transcribe_crispasr.sh" "$SCRIPT_DIR/transcribe_crispasr.sh"

echo
echo "--- PyTorch (transformers) ---"
check_executable "venv python"            "$VENV_PY"
check_executable "scripts/transcribe_local.sh"    "$SCRIPT_DIR/transcribe_local.sh"
check_executable "scripts/transcribe.py"          "$SCRIPT_DIR/transcribe.py"

if [[ -x "$VENV_PY" ]]; then
  if "$VENV_PY" -c "import qwen_asr" 2>/dev/null; then
    printf 'OK   %-30s\n' "qwen_asr package importable"
  else
    printf 'MISS %-30s run setup/setup_venv.sh\n' "qwen_asr package"
  fi
fi

echo
echo "--- Whisper-server fallback ---"
# Derive server root from the transcription URL (strip /v1/audio/transcriptions)
_WHISPER_ROOT="$(echo "$WHISPER_URL" | sed 's|/v1/audio/transcriptions.*||')"
if curl -sf --max-time 3 "${_WHISPER_ROOT}/health" -o /dev/null 2>/dev/null \
   || curl -sf --max-time 3 "$_WHISPER_ROOT/" -o /dev/null 2>/dev/null; then
  printf 'OK   %-30s %s\n' "whisper-server" "$WHISPER_URL"
else
  printf 'MISS %-30s %s (not reachable)\n' "whisper-server" "$WHISPER_URL"
fi

echo
echo "--- Tools ---"
if command -v ffmpeg >/dev/null 2>&1; then
  printf 'OK   %-30s %s\n' "ffmpeg" "$(command -v ffmpeg)"
else
  printf 'MISS %-30s not found in PATH\n' "ffmpeg"
fi
if command -v curl >/dev/null 2>&1; then
  printf 'OK   %-30s %s\n' "curl" "$(command -v curl)"
else
  printf 'MISS %-30s not found in PATH\n' "curl"
fi
_YTDLP="${QWEN3_ASR_YTDLP:-yt-dlp}"
if command -v "$_YTDLP" >/dev/null 2>&1; then
  printf 'OK   %-30s %s\n' "yt-dlp" "$(command -v "$_YTDLP")"
else
  printf 'MISS %-30s not found (needed for --url)\n' "yt-dlp"
fi

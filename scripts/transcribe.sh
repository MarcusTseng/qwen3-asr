#!/usr/bin/env bash
# transcribe.sh — top-level Qwen3-ASR entrypoint.
# Selects backend (crisp → torch → whisper) and wraps output.
# Stdout: transcript text (or JSON with --output json).
# Stderr: diagnostics only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env from repo root if present (does not override already-set vars)
if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

usage() {
  cat >&2 <<'USAGE'
Usage: transcribe.sh [OPTIONS] <audio_file>

Options:
  --backend  auto|crisp|torch|whisper   Backend to use (default: auto)
  --language <lang>                     Language hint, e.g. zh, en, yue (default: auto-detect)
  --output   text|json                  Output format (default: text)
  -h, --help                            Show this help

Environment overrides (also loadable via .env in repo root):
  QWEN3_ASR_BACKEND          auto|crisp|torch|whisper
  QWEN3_ASR_LANGUAGE         language hint passed to backends
  QWEN3_ASR_OUTPUT           text|json
  QWEN3_ASR_CRISP_SCRIPT     path to transcribe_crispasr.sh
  QWEN3_ASR_TORCH_SCRIPT     path to transcribe_local.sh
  WHISPER_SERVER_URL         whisper-server HTTP endpoint (default: http://localhost:8082/v1/audio/transcriptions)
USAGE
}

BACKEND="${QWEN3_ASR_BACKEND:-auto}"
LANGUAGE="${QWEN3_ASR_LANGUAGE:-}"
OUTPUT_FMT="${QWEN3_ASR_OUTPUT:-text}"
AUDIO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)   BACKEND="${2:-}";   shift 2 ;;
    --backend=*) BACKEND="${1#--backend=}"; shift ;;
    --language)  LANGUAGE="${2:-}";  shift 2 ;;
    --language=*)LANGUAGE="${1#--language=}"; shift ;;
    --output)    OUTPUT_FMT="${2:-}"; shift 2 ;;
    --output=*)  OUTPUT_FMT="${1#--output=}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
    *)           AUDIO="$1"; shift ;;
  esac
done

[[ -z "$AUDIO" && $# -gt 0 ]] && AUDIO="$1"
[[ -z "$AUDIO" ]] && { usage; exit 2; }
[[ ! -f "$AUDIO" ]] && { echo "Error: input audio not found: $AUDIO" >&2; exit 2; }

case "$BACKEND" in
  auto|crisp|torch|whisper) ;;
  *) echo "Error: unsupported backend '$BACKEND'" >&2; exit 2 ;;
esac
case "$OUTPUT_FMT" in
  text|json) ;;
  *) echo "Error: unsupported output format '$OUTPUT_FMT'" >&2; exit 2 ;;
esac

CRISP_SCRIPT="${QWEN3_ASR_CRISP_SCRIPT:-$SCRIPT_DIR/transcribe_crispasr.sh}"
TORCH_SCRIPT="${QWEN3_ASR_TORCH_SCRIPT:-$SCRIPT_DIR/transcribe_local.sh}"
WHISPER_URL="${WHISPER_SERVER_URL:-http://localhost:8082/v1/audio/transcriptions}"

# Export language for child scripts
[[ -n "$LANGUAGE" ]] && export QWEN3_ASR_LANGUAGE="$LANGUAGE"

_now_ms() { date +%s%3N 2>/dev/null || echo 0; }

run_crisp() {
  [[ ! -x "$CRISP_SCRIPT" ]] && { echo "CrispASR backend unavailable: $CRISP_SCRIPT not executable" >&2; return 127; }
  "$CRISP_SCRIPT" "$AUDIO"
}

run_torch() {
  [[ ! -x "$TORCH_SCRIPT" ]] && { echo "PyTorch backend unavailable: $TORCH_SCRIPT not executable" >&2; return 127; }
  "$TORCH_SCRIPT" "$AUDIO"
}

run_whisper() {
  if ! curl -sf --max-time 5 "$WHISPER_URL" -o /dev/null 2>/dev/null; then
    echo "whisper-server not reachable at $WHISPER_URL" >&2
    return 1
  fi
  curl -sS --max-time 300 -X POST "$WHISPER_URL" \
    -F "file=@$AUDIO" \
    -F "model=whisper-1" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','').strip())"
}

_emit() {
  local text="$1" backend="$2" elapsed="$3"
  if [[ "$OUTPUT_FMT" == "json" ]]; then
    # Escape text for JSON
    local escaped
    escaped="$(printf '%s' "$text" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")"
    printf '{"text":%s,"language":"%s","backend":"%s","elapsed_ms":%s}\n' \
      "$escaped" "${LANGUAGE:-}" "$backend" "$elapsed"
  else
    printf '%s\n' "$text"
  fi
}

run_auto() {
  local tmp status t0 t1 text
  tmp="$(mktemp /tmp/qwen3-asr-transcript.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN

  echo "qwen3-asr: trying CrispASR backend" >&2
  t0="$(_now_ms)"
  if run_crisp >"$tmp"; then
    t1="$(_now_ms)"
    text="$(cat "$tmp")"
    _emit "$text" "crisp" "$((t1 - t0))"
    return 0
  fi
  status=$?
  echo "qwen3-asr: CrispASR failed (status $status); trying PyTorch backend" >&2

  t0="$(_now_ms)"
  if run_torch >"$tmp"; then
    t1="$(_now_ms)"
    text="$(cat "$tmp")"
    _emit "$text" "torch" "$((t1 - t0))"
    return 0
  fi
  status=$?
  echo "qwen3-asr: PyTorch backend failed (status $status); trying whisper-server fallback" >&2

  t0="$(_now_ms)"
  if run_whisper >"$tmp"; then
    t1="$(_now_ms)"
    text="$(cat "$tmp")"
    _emit "$text" "whisper" "$((t1 - t0))"
    return 0
  fi
  status=$?
  echo "qwen3-asr: all backends failed; final status $status" >&2
  return "$status"
}

_run_named() {
  local backend="$1" fn="$2"
  local tmp t0 t1 text
  tmp="$(mktemp /tmp/qwen3-asr-transcript.XXXXXX)"
  trap 'rm -f "$tmp"' RETURN
  t0="$(_now_ms)"
  "$fn" >"$tmp"
  t1="$(_now_ms)"
  text="$(cat "$tmp")"
  _emit "$text" "$backend" "$((t1 - t0))"
}

case "$BACKEND" in
  auto)    run_auto ;;
  crisp)   _run_named crisp run_crisp ;;
  torch)   _run_named torch run_torch ;;
  whisper) _run_named whisper run_whisper ;;
esac

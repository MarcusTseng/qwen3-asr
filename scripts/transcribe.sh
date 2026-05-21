#!/usr/bin/env bash
# transcribe.sh — top-level Qwen3-ASR entrypoint.
# Selects backend (crisp → torch → whisper) and wraps output.
# Stdout: transcript text (or JSON with --output json).
# Stderr: diagnostics only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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
       transcribe.sh [OPTIONS] --url <youtube_or_audio_url>

Options:
  --backend  auto|crisp|torch|whisper   Backend to use (default: auto)
  --language <lang>                     Language hint, e.g. zh, en, yue (default: auto-detect)
  --output   text|json                  Output format (default: text)
  --url      <url>                      Download from YouTube, podcast RSS, or direct audio URL
  --episodes <N>                        Max episodes to download from RSS/playlist (default: 1)
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
INPUT_URL=""
EPISODES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      [[ $# -lt 2 ]] && { echo "Error: --backend requires a value" >&2; exit 2; }
      BACKEND="$2"; shift 2 ;;
    --backend=*) BACKEND="${1#--backend=}"; shift ;;
    --language)
      [[ $# -lt 2 ]] && { echo "Error: --language requires a value" >&2; exit 2; }
      LANGUAGE="$2"; shift 2 ;;
    --language=*) LANGUAGE="${1#--language=}"; shift ;;
    --output)
      [[ $# -lt 2 ]] && { echo "Error: --output requires a value" >&2; exit 2; }
      OUTPUT_FMT="$2"; shift 2 ;;
    --output=*) OUTPUT_FMT="${1#--output=}"; shift ;;
    --url)
      [[ $# -lt 2 ]] && { echo "Error: --url requires a value" >&2; exit 2; }
      INPUT_URL="$2"; shift 2 ;;
    --url=*) INPUT_URL="${1#--url=}"; shift ;;
    --episodes)
      [[ $# -lt 2 ]] && { echo "Error: --episodes requires a value" >&2; exit 2; }
      EPISODES="$2"; shift 2 ;;
    --episodes=*) EPISODES="${1#--episodes=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
    *)          AUDIO="$1"; shift ;;
  esac
done

[[ -z "$AUDIO" && $# -gt 0 ]] && AUDIO="$1"
[[ -z "$AUDIO" && -z "$INPUT_URL" ]] && { usage; exit 2; }
[[ -n "$AUDIO" && ! -f "$AUDIO" ]] && { echo "Error: input audio not found: $AUDIO" >&2; exit 2; }

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

# Single temp directory for all intermediate files.
# Cleaned on EXIT (RETURN trap is bypassed by set -e exits; array-in-subshell
# tracking is unreliable because $() forks a subshell where mutations are lost).
_TMPDIR="$(mktemp -d /tmp/qwen3-asr.XXXXXX)"
_cleanup() { rm -rf "$_TMPDIR"; }
trap _cleanup EXIT

_mktmp() { mktemp "$_TMPDIR/transcript.XXXXXX"; }

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
  local curl_args=(
    -sS --max-time 300 -X POST "$WHISPER_URL"
    -F "file=@$AUDIO"
    -F "model=whisper-1"
    -F "response_format=json"
  )
  [[ -n "$LANGUAGE" ]] && curl_args+=( -F "language=$LANGUAGE" )

  curl "${curl_args[@]}" | python3 -c "
import sys, json
try:
    text = json.load(sys.stdin).get('text', '').strip()
    if not text:
        print('Error: whisper-server returned empty transcript', file=sys.stderr)
        sys.exit(1)
    print(text)
except (json.JSONDecodeError, KeyError):
    print('Error: whisper-server returned unexpected response', file=sys.stderr)
    sys.exit(1)
"
}

# Use Python json.dumps for all fields to prevent JSON injection
_emit() {
  local text="$1" backend="$2" elapsed="$3"
  if [[ "$OUTPUT_FMT" == "json" ]]; then
    python3 -c '
import sys, json
text, lang, backend, elapsed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({"text": text, "language": lang, "backend": backend, "elapsed_ms": int(elapsed)}))
' "$text" "${LANGUAGE:-}" "$backend" "$elapsed"
  else
    printf '%s\n' "$text"
  fi
}

run_auto() {
  local tmp status t0 t1 text
  tmp="$(_mktmp)"

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
  tmp="$(_mktmp)"
  t0="$(_now_ms)"
  "$fn" >"$tmp"
  t1="$(_now_ms)"
  text="$(cat "$tmp")"
  _emit "$text" "$backend" "$((t1 - t0))"
}

# --- URL download mode ---
if [[ -n "$INPUT_URL" ]]; then
  DL_DIR="$_TMPDIR/dl"
  mkdir -p "$DL_DIR"
  echo "qwen3-asr: downloading audio from URL ..." >&2

  mapfile -t _DL_FILES < <(
    "$SCRIPT_DIR/download.sh" \
      --output-dir "$DL_DIR" \
      --episodes "$EPISODES" \
      "$INPUT_URL"
  )

  if [[ ${#_DL_FILES[@]} -eq 0 ]]; then
    echo "Error: download produced no audio files from: $INPUT_URL" >&2
    exit 1
  fi

  _EP_IDX=0
  for AUDIO in "${_DL_FILES[@]}"; do
    # Print a separator between episodes so multi-episode output isn't a wall of text
    if [[ $_EP_IDX -gt 0 ]]; then
      printf '\n\n=== %s ===\n\n' "$(basename "$AUDIO" .wav)"
    fi
    _EP_IDX=$((_EP_IDX + 1))
    echo "qwen3-asr: transcribing $(basename "$AUDIO") ..." >&2
    case "$BACKEND" in
      auto)    run_auto ;;
      crisp)   _run_named crisp run_crisp ;;
      torch)   _run_named torch run_torch ;;
      whisper) _run_named whisper run_whisper ;;
    esac
  done
  exit 0
fi

# --- Single local file mode ---
case "$BACKEND" in
  auto)    run_auto ;;
  crisp)   _run_named crisp run_crisp ;;
  torch)   _run_named torch run_torch ;;
  whisper) _run_named whisper run_whisper ;;
esac

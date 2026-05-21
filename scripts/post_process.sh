#!/usr/bin/env bash
# post_process.sh — LLM-based transcript cleanup for qwen3-asr output.
# Uses a local OpenAI-compatible LLM (default: localhost:8081) to:
#   1. Apply domain corrections (e.g. 骨癌 → 股癌)
#   2. Fix paragraph structure and punctuation
#   3. Optionally generate a summary
#
# Usage: post_process.sh [OPTIONS] <transcript.txt>
#        cat transcript.txt | post_process.sh [OPTIONS]
#
# Options:
#   --corrections FILE   TSV of wrong→correct replacements (default: auto-detect)
#   --api-base URL       OpenAI-compatible API base (default: http://localhost:8081/v1)
#   --model MODEL        Model to use (default: first model from /v1/models)
#   --context TEXT       Domain context hint for the LLM
#   --summary            Also output a summary section
#   --raw                Skip LLM step; only run deterministic cleanup/corrections
#   --no-deterministic   Skip deterministic cleanup (OpenCC/fillers/dictionary)
#   -o FILE              Write to file instead of stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a; source "$REPO_DIR/.env"; set +a
fi

API_BASE="${QWEN3_POST_API_BASE:-${OPENAI_API_BASE:-http://localhost:8081/v1}}"
MODEL="${QWEN3_POST_MODEL:-}"
CORRECTIONS_FILE="${QWEN3_POST_CORRECTIONS:-}"
CONTEXT="${QWEN3_POST_CONTEXT:-}"
DO_SUMMARY=0
RAW_ONLY=0
DETERMINISTIC=1
OUT_FILE=""
INPUT_FILE=""

usage() {
  sed -n '3,18p' "$0" | sed 's/^# //' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --corrections)   CORRECTIONS_FILE="$2"; shift 2 ;;
    --corrections=*) CORRECTIONS_FILE="${1#--corrections=}"; shift ;;
    --api-base)      API_BASE="$2"; shift 2 ;;
    --api-base=*)    API_BASE="${1#--api-base=}"; shift ;;
    --model)         MODEL="$2"; shift 2 ;;
    --model=*)       MODEL="${1#--model=}"; shift ;;
    --context)       CONTEXT="$2"; shift 2 ;;
    --context=*)     CONTEXT="${1#--context=}"; shift ;;
    --summary)       DO_SUMMARY=1; shift ;;
    --raw)           RAW_ONLY=1; shift ;;
    --no-deterministic) DETERMINISTIC=0; shift ;;
    -o)              OUT_FILE="$2"; shift 2 ;;
    -o*)             OUT_FILE="${1#-o}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; break ;;
    -*)              echo "Error: unknown option: $1" >&2; exit 2 ;;
    *)               INPUT_FILE="$1"; shift ;;
  esac
done

# Read input
if [[ -n "$INPUT_FILE" ]]; then
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: not found: $INPUT_FILE" >&2; exit 1; }
  TEXT="$(cat "$INPUT_FILE")"
else
  TEXT="$(cat)"
fi

[[ -z "$TEXT" ]] && { echo "Error: empty input" >&2; exit 1; }

# Auto-detect corrections file next to input or in repo
if [[ -z "$CORRECTIONS_FILE" ]]; then
  for candidate in \
    "${INPUT_FILE:+$(dirname "$INPUT_FILE")/corrections.tsv}" \
    "$REPO_DIR/data/corrections.tsv"; do
    [[ -n "$candidate" && -f "$candidate" ]] && { CORRECTIONS_FILE="$candidate"; break; }
  done
fi

# Deterministic cleanup inspired by HushType:
# OpenCC s2twp (when available), filler cleanup, duplicate collapse, and a
# HushType-style longest-first non-cascading dictionary/corrections pass.
if [[ "$DETERMINISTIC" == "1" ]]; then
  _TMP_DET="$(mktemp /tmp/qwen3-deterministic.XXXXXX)"
  printf '%s' "$TEXT" > "$_TMP_DET"
  CLEAN_ARGS=("$SCRIPT_DIR/clean_transcript.py")
  if [[ -n "$CORRECTIONS_FILE" && -f "$CORRECTIONS_FILE" ]]; then
    echo "post_process: applying deterministic cleanup and corrections from $CORRECTIONS_FILE" >&2
    CLEAN_ARGS+=(--corrections "$CORRECTIONS_FILE")
  else
    echo "post_process: applying deterministic cleanup" >&2
  fi
  CLEAN_ARGS+=("$_TMP_DET")
  TEXT="$(python3 "${CLEAN_ARGS[@]}")"
  rm -f "$_TMP_DET"
fi

if [[ "$RAW_ONLY" == "1" ]]; then
  if [[ -n "$OUT_FILE" ]]; then printf '%s\n' "$TEXT" > "$OUT_FILE"
  else printf '%s\n' "$TEXT"; fi
  exit 0
fi

# Resolve model if not specified
if [[ -z "$MODEL" ]]; then
  MODEL="$(curl -sf "$API_BASE/models" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
print(data[0]['id'] if data else '') " 2>/dev/null || true)"
  [[ -z "$MODEL" ]] && { echo "Error: cannot resolve model from $API_BASE/models" >&2; exit 1; }
  echo "post_process: using model $MODEL" >&2
fi

SYSTEM_PROMPT="你是一個專業的繁體中文播客謄寫編輯。
你的任務是清理 ASR（語音識別）產生的原始逐字稿，使其更易閱讀。

規則：
1. 保持所有實質內容，不要刪除或改寫意思。
2. 修正明顯的 ASR 錯字；優先相信前置 deterministic cleanup / corrections.tsv 已完成的專有名詞修正，不要自行引入未提供的節目或人名。
3. 加入適當的段落分隔（對話主題轉換時換行）。
4. 修正標點符號（漏掉的句號、問號、逗號等）。
5. 英文和數字保持原樣。
6. 直接輸出修改後的全文，不要加任何說明或前言。
${CONTEXT:+
補充背景：$CONTEXT}"

if [[ "$DO_SUMMARY" == "1" ]]; then
  SYSTEM_PROMPT+="
7. 在文末加一個「---」分隔線，然後用繁體中文寫 3-5 條重點摘要，以 • 開頭。"
fi

# Write transcript to temp file so stdin is free for the Python heredoc.
# (bash: heredoc for `python3 -` and `< <(...)` both compete for the same
#  stdin — the heredoc wins and the process substitution is silently ignored.)
_TMP_TEXT="$(mktemp /tmp/qwen3-post.XXXXXX)"
printf '%s' "$TEXT" > "$_TMP_TEXT"
_cleanup_tmp() { rm -f "$_TMP_TEXT"; }
trap _cleanup_tmp EXIT

# Call local LLM — reads transcript from file (argv[4]), not stdin
RESULT="$(python3 - "$API_BASE" "$MODEL" "$SYSTEM_PROMPT" "$_TMP_TEXT" <<'PYEOF'
import sys, json, urllib.request, urllib.error

api_base, model, system_prompt, text_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(text_file) as f:
    user_text = f.read()

payload = json.dumps({
    "model": model,
    "messages": [
        {"role": "system", "content": system_prompt},
        {"role": "user",   "content": user_text}
    ],
    "temperature": 0.2,
    "stream": False
}).encode()

req = urllib.request.Request(
    f"{api_base}/chat/completions",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.load(resp)
        print(data["choices"][0]["message"]["content"], end="")
except urllib.error.URLError as e:
    print(f"Error: LLM API call failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)"

if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$RESULT" > "$OUT_FILE"
  echo "post_process: saved to $OUT_FILE" >&2
else
  printf '%s\n' "$RESULT"
fi

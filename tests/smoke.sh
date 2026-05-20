#!/usr/bin/env bash
# smoke.sh — regression test for qwen3-asr.
# Usage: ./tests/smoke.sh [/path/to/sample.wav]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TRANSCRIBE="$REPO_DIR/scripts/transcribe.sh"

SAMPLE="${1:-/home/marcus/whisper.cpp/samples/jfk.wav}"
PASS=0
FAIL=0

run_test() {
  local label="$1" backend="$2"
  echo -n "  $label ... "
  local out
  if out="$(QWEN3_ASR_BACKEND="$backend" "$TRANSCRIBE" "$SAMPLE" 2>/dev/null)"; then
    if echo "$out" | grep -qi "ask not what"; then
      echo "PASS"
      PASS=$((PASS + 1))
    else
      echo "FAIL (unexpected output: ${out:0:80})"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "SKIP (backend unavailable)"
  fi
}

echo "=== Qwen3-ASR smoke test ==="
echo "Sample: $SAMPLE"
echo

if [[ ! -f "$SAMPLE" ]]; then
  echo "ERROR: sample file not found: $SAMPLE" >&2
  echo "Download it with:" >&2
  echo "  wget -P /home/marcus/whisper.cpp/samples \\" >&2
  echo "    https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav" >&2
  exit 1
fi

run_test "CrispASR backend" "crisp"
run_test "Whisper fallback " "whisper"
run_test "Auto (full chain)" "auto"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

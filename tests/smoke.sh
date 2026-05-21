#!/usr/bin/env bash
# smoke.sh — regression test for qwen3-asr.
# Usage: ./tests/smoke.sh [/path/to/sample.wav]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TRANSCRIBE="$REPO_DIR/scripts/transcribe.sh"

SAMPLE="${1:-}"
if [[ -z "$SAMPLE" ]]; then
  # Look for a sample in common locations
  for candidate in \
    "$(dirname "$SCRIPT_DIR")/assets/jfk.wav" \
    /usr/share/qwen3-asr/samples/jfk.wav \
    "$HOME/whisper.cpp/samples/jfk.wav"; do
    if [[ -f "$candidate" ]]; then SAMPLE="$candidate"; break; fi
  done
fi
PASS=0
FAIL=0

run_test() {
  local label="$1" backend="$2"
  echo -n "  $label ... "
  local out
  if out="$(QWEN3_ASR_BACKEND="$backend" "$TRANSCRIBE" "$SAMPLE" 2>/dev/null)"; then
    if python3 - "$out" <<'PY'
import re, sys
text = sys.argv[1].lower()
sys.exit(0 if re.search(r"ask not\W+what", text) else 1)
PY
    then
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

if [[ -z "$SAMPLE" || ! -f "$SAMPLE" ]]; then
  echo "ERROR: no sample file found." >&2
  echo "Provide a WAV file as argument, or download the JFK sample:" >&2
  echo "  wget -O /tmp/jfk.wav https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav" >&2
  echo "  ./tests/smoke.sh /tmp/jfk.wav" >&2
  exit 1
fi

run_test "CrispASR backend" "crisp"
run_test "Whisper fallback " "whisper"
run_test "Auto (full chain)" "auto"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

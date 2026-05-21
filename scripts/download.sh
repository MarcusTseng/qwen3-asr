#!/usr/bin/env bash
# download.sh — Download audio from a URL for ASR transcription.
# Supports YouTube, podcast RSS feeds, and direct audio/video URLs.
#
# Stdout: absolute paths to downloaded 16kHz mono WAV files, one per line.
# Stderr: yt-dlp progress and diagnostics.
#
# Usage: download.sh --output-dir <dir> [OPTIONS] <url>
#
# Options:
#   --output-dir DIR   Directory to save files (must already exist) [required]
#   --episodes N       Max episodes from RSS/playlist (default: 1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

YT_DLP="${QWEN3_ASR_YTDLP:-yt-dlp}"
OUTPUT_DIR=""
EPISODES=1
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -lt 2 ]] && { echo "Error: --output-dir requires a value" >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --output-dir=*) OUTPUT_DIR="${1#--output-dir=}"; shift ;;
    --episodes)
      [[ $# -lt 2 ]] && { echo "Error: --episodes requires a value" >&2; exit 2; }
      EPISODES="$2"; shift 2 ;;
    --episodes=*) EPISODES="${1#--episodes=}"; shift ;;
    --) shift; break ;;
    -*) echo "Error: unknown option: $1" >&2; exit 2 ;;
    *) URL="$1"; shift ;;
  esac
done

# BUG FIX: capture URL from remaining positional arg after `--` separator
[[ -z "$URL" && $# -gt 0 ]] && { URL="$1"; shift; }

[[ -z "$URL" ]]        && { echo "Usage: $0 --output-dir <dir> [--episodes N] <url>" >&2; exit 2; }
[[ -z "$OUTPUT_DIR" ]] && { echo "Error: --output-dir is required" >&2; exit 2; }
[[ ! -d "$OUTPUT_DIR" ]] && { echo "Error: output directory does not exist: $OUTPUT_DIR" >&2; exit 2; }

# Detect RSS/podcast feed URLs
_is_rss() {
  echo "$1" | grep -qiE "\.(rss|xml)$|/feed(/|$)|/rss(/|$)|/podcast|feeds\."
}

YTDLP_ARGS=(
  -x
  --audio-format wav
  --audio-quality 0
  --postprocessor-args "ffmpeg:-ar 16000 -ac 1 -acodec pcm_s16le"
  --retries 10
  --fragment-retries 10
  --throttled-rate 100K
  --extractor-args "youtube:player_client=default,-android_sdkless"
  --no-progress
  --newline
  -o "$OUTPUT_DIR/%(title).120s.%(ext)s"
)

if _is_rss "$URL" || [[ "$EPISODES" -gt 1 ]]; then
  YTDLP_ARGS+=(--playlist-end "$EPISODES")
else
  YTDLP_ARGS+=(--no-playlist)
fi

# Snapshot pre-existing WAVs so we only report files downloaded this run
declare -A _PRE_WAV
while IFS= read -r f; do _PRE_WAV["$f"]=1; done < <(
  find "$OUTPUT_DIR" -maxdepth 1 -name "*.wav" -print 2>/dev/null
)

# `--` prevents a URL that starts with `-` from being parsed as a yt-dlp flag
"$YT_DLP" "${YTDLP_ARGS[@]}" -- "$URL" >&2

# Print only newly downloaded WAV paths
while IFS= read -r f; do
  [[ -z "${_PRE_WAV[$f]+x}" ]] && printf '%s\n' "$f"
done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "*.wav" -print | sort)

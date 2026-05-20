#!/usr/bin/env bash
# setup_venv.sh — create venv and install Python dependencies.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SETUP_DIR")"
VENV_DIR="${QWEN3_ASR_VENV:-$REPO_DIR/venv}"

echo "Creating venv at $VENV_DIR ..."
python3 -m venv "$VENV_DIR"

echo "Upgrading pip ..."
"$VENV_DIR/bin/pip" install -U pip --quiet

echo "Installing requirements ..."
"$VENV_DIR/bin/pip" install -r "$REPO_DIR/requirements.txt"

echo
echo "Done. Venv ready at: $VENV_DIR"
echo "Run: $REPO_DIR/scripts/status.sh"

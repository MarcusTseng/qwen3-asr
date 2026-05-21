#!/usr/bin/env bash
# setup_venv.sh — create venv and install Python dependencies.
#
# On AMD (ROCm) systems, installs PyTorch with ROCm wheels automatically.
# Set ROCM_VERSION env var to override (default: rocm6.2).
# Set QWEN3_ASR_TORCH_DEVICE=cpu to force CPU-only install.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SETUP_DIR")"
VENV_DIR="${QWEN3_ASR_VENV:-$REPO_DIR/venv}"
ROCM_VERSION="${ROCM_VERSION:-rocm6.2}"
FORCE_DEVICE="${QWEN3_ASR_TORCH_DEVICE:-}"

echo "Creating venv at $VENV_DIR ..."
python3 -m venv "$VENV_DIR"
PIP="$VENV_DIR/bin/pip"

echo "Upgrading pip ..."
"$PIP" install -U pip --quiet

# Detect AMD GPU / ROCm — install ROCm-enabled PyTorch unless forced CPU
_install_rocm=0
if [[ "$FORCE_DEVICE" != "cpu" ]]; then
  if command -v rocminfo >/dev/null 2>&1 || ls /dev/kfd >/dev/null 2>&1; then
    _install_rocm=1
  fi
fi

if [[ "$_install_rocm" == "1" ]]; then
  echo "AMD ROCm detected — installing PyTorch with ROCm wheels ($ROCM_VERSION) ..."
  "$PIP" install --quiet \
    torch torchvision torchaudio \
    --index-url "https://download.pytorch.org/whl/$ROCM_VERSION"
else
  echo "Installing PyTorch (CPU) ..."
  "$PIP" install --quiet torch torchaudio --index-url https://download.pytorch.org/whl/cpu
fi

echo "Installing qwen-asr and dependencies ..."
"$PIP" install -r "$REPO_DIR/requirements.txt" --quiet

echo
echo "Done. Venv ready at: $VENV_DIR"
echo "Run: $REPO_DIR/scripts/status.sh"

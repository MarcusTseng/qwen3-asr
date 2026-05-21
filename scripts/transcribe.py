#!/usr/bin/env python3
"""
Qwen3-ASR PyTorch/transformers inference worker.

Rules:
- Chinese audio  → Traditional Chinese output (via opencc)
- English audio  → English output
- Other language → whisper-server HTTP fallback for translation to English
- Unknown lang   → pass through as-is

Stdout: transcript text only.
Stderr: diagnostics.
"""
import json
import logging
import os
import subprocess
import sys
import warnings
from pathlib import Path


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def is_chinese_language(lang: str) -> bool:
    return (lang or '').strip().lower() in {
        'chinese', 'zh', 'zh-cn', 'zh-tw', 'mandarin', 'cantonese', 'yue'
    }


def is_english_language(lang: str) -> bool:
    return (lang or '').strip().lower() in {'english', 'en', 'en-us', 'en-gb'}


def to_traditional_chinese(text: str) -> str:
    from opencc import OpenCC
    # s2twp: Taiwan-optimized — fixes 发现→發現 (not 髮現) and other homophones
    return OpenCC('s2twp').convert(text)


def translate_with_whisper_server(audio_file: str) -> str:
    url = os.environ.get('WHISPER_SERVER_URL', 'http://localhost:8082/v1/audio/transcriptions')
    try:
        import requests
        with open(audio_file, 'rb') as f:
            resp = requests.post(
                url,
                files={'file': (Path(audio_file).name, f)},
                data={'model': 'whisper-1'},
                timeout=120,
            )
            resp.raise_for_status()
            return resp.json().get('text', '').strip()
    except ImportError:
        pass
    except (KeyError, ValueError) as e:
        raise RuntimeError(f'whisper-server returned unexpected JSON: {e}') from e

    # Last-resort curl fallback (requests not installed).
    # Note: filenames containing ';' may confuse curl's -F parser.
    # Install 'requests' via setup/setup_venv.sh to avoid this path.
    result = subprocess.run(
        ['curl', '-sS', '--max-time', '120', '-X', 'POST', url,
         '-F', f'file=@{audio_file}', '-F', 'model=whisper-1'],
        capture_output=True, text=True, check=True,
    )
    try:
        return json.loads(result.stdout).get('text', '').strip()
    except (json.JSONDecodeError, KeyError) as e:
        raise RuntimeError(f'whisper-server returned unexpected response: {e}') from e


if len(sys.argv) < 2:
    print('Usage: transcribe.py <path_to_audio_file>', file=sys.stderr)
    sys.exit(1)

audio_file = sys.argv[1]
if not os.path.exists(audio_file):
    eprint(f"Error: file '{audio_file}' not found.")
    sys.exit(1)

# Language hint from environment (set by transcribe.sh or user)
language_hint = os.environ.get('QWEN3_ASR_LANGUAGE') or None

# Model selection: default 1.7B for best accuracy; override via env for lighter load
_model_id = os.environ.get('QWEN3_ASR_TORCH_MODEL', 'Qwen/Qwen3-ASR-1.7B')

# Device: 'auto' picks ROCm/CUDA if available, falls back to CPU
_device_map = os.environ.get('QWEN3_ASR_TORCH_DEVICE', 'auto')

try:
    import torch
    from qwen_asr import Qwen3ASRModel

    warnings.filterwarnings('ignore')
    logging.getLogger('transformers').setLevel(logging.ERROR)

    # bfloat16 requires native HW support — not just CUDA availability.
    # Older GPUs and some AMD ROCm targets silently fall back to float32 emulation
    # which is slow. Check is_bf16_supported() when available (torch >= 1.10).
    def _pick_dtype() -> torch.dtype:
        if not torch.cuda.is_available():
            return torch.float32
        try:
            if torch.cuda.is_bf16_supported():
                return torch.bfloat16
        except AttributeError:
            pass
        return torch.float32
    _dtype = _pick_dtype()

    model = Qwen3ASRModel.from_pretrained(
        _model_id,
        device_map=_device_map,
        torch_dtype=_dtype,
        trust_remote_code=True,
        max_new_tokens=4096,
    )

    results = model.transcribe(audio_file, language=language_hint)
    if not isinstance(results, list) or not results:
        raise RuntimeError('Qwen3-ASR returned no result')

    item = results[0]
    detected_language = getattr(item, 'language', '') or ''
    text = (getattr(item, 'text', '') or '').strip()

    if not text:
        print('')
        sys.exit(0)

    if is_chinese_language(detected_language):
        print(to_traditional_chinese(text))
    elif is_english_language(detected_language) or detected_language == '':
        print(text)
    else:
        eprint(f"Qwen3-ASR detected '{detected_language}'; translating to English via whisper-server fallback")
        translated = translate_with_whisper_server(audio_file)
        print(translated)

except Exception as e:
    eprint(f'Transcription failed: {e}')
    sys.exit(1)

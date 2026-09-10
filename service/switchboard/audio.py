"""Bytes in, 16 kHz mono float32 out.

Any WAV/FLAC/OGG soundfile can read; any sample rate. Stereo is averaged to
mono. Resampling uses `resample_poly`, which low-passes before decimating -
the anti-alias step that dialtone found most people skip. 8 kHz phone audio
therefore arrives here and is upsampled correctly.
"""

from __future__ import annotations

import io
from math import gcd

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from .model import SR


class BadAudio(ValueError):
    pass


def decode(data: bytes, max_seconds: float) -> tuple[np.ndarray, int]:
    """Returns (audio at 16 kHz float32 mono, original sample rate)."""
    try:
        x, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=False)
    except Exception as e:  # soundfile raises several types
        raise BadAudio(f"could not decode audio: {e}") from e
    if x.ndim > 1:
        x = x.mean(axis=1)
    if len(x) == 0:
        raise BadAudio("empty audio")
    if len(x) / sr > max_seconds:
        raise BadAudio(f"audio is {len(x) / sr:.1f} s; limit is {max_seconds:.0f} s")
    if sr != SR:
        g = gcd(SR, sr)
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return np.ascontiguousarray(x, dtype=np.float32), sr

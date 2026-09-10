"""Every knob is an environment variable, so the same image runs everywhere.

MODEL_ID   HF hub id or local path (default: the model dialtone chose)
DEVICE     auto | cpu | cuda            (auto: cuda if available)
DTYPE      auto | fp32 | fp16 | bf16    (auto: fp32 - the model card's default)
PORT       listening port
FAKE_MODEL 1 -> a stub that never loads weights; for tests and cluster dry-runs
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    model_id: str = os.environ.get("MODEL_ID", "nvidia/parakeet-tdt-0.6b-v3")
    device: str = os.environ.get("DEVICE", "auto")
    dtype: str = os.environ.get("DTYPE", "auto")
    port: int = int(os.environ.get("PORT", "8000"))
    fake_model: bool = os.environ.get("FAKE_MODEL", "0") == "1"
    max_audio_seconds: float = float(os.environ.get("MAX_AUDIO_SECONDS", "60"))


def load() -> Settings:
    return Settings()

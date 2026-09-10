"""The model behind the service.

`ParakeetModel` is the adapter from dialtone (`dialtone/src/dialtone/models.py`,
class ParakeetHF) with the same missing-weights guard: transformers only *warns*
when a checkpoint doesn't match the class and initialises the rest at random - a
server that loads that way answers every request with confident nonsense. So a
checkpoint with missing weights is refused, loudly, at startup.

`FakeModel` is a stub for tests and for cluster dry-runs without weights or a GPU.
"""

from __future__ import annotations

import time
from typing import Protocol

import numpy as np

SR = 16_000


class Transcriber(Protocol):
    device: str
    dtype: str
    load_seconds: float

    def transcribe(self, audios: list[np.ndarray]) -> list[str]: ...

    def info(self) -> dict: ...


class FakeModel:
    """Returns a fixed phrase; costs nothing. FAKE_MODEL=1."""

    device = "cpu"
    dtype = "none"

    def __init__(self, delay_s: float = 0.0):
        t0 = time.perf_counter()
        self.delay_s = delay_s
        self.load_seconds = time.perf_counter() - t0

    def transcribe(self, audios: list[np.ndarray]) -> list[str]:
        if self.delay_s:
            time.sleep(self.delay_s)
        return [f"fake transcript of {len(a) / SR:.1f} seconds" for a in audios]

    def info(self) -> dict:
        return {"class": "FakeModel", "device": self.device, "dtype": self.dtype}


class ParakeetModel:
    def __init__(self, model_id: str, device: str = "auto", dtype: str = "auto"):
        import torch
        from transformers import AutoConfig, AutoModelForCTC, AutoModelForTDT, AutoProcessor

        t0 = time.perf_counter()
        self.model_id = model_id
        self.device = ("cuda:0" if torch.cuda.is_available() else "cpu") if device == "auto" else device
        wanted = "fp32" if dtype == "auto" else dtype
        if not self.device.startswith("cuda"):
            wanted = "fp32"  # half precision on CPU is slow and often unsupported
        self.torch_dtype = {"fp32": torch.float32, "fp16": torch.float16, "bf16": torch.bfloat16}[wanted]
        self.dtype = wanted

        model_type = AutoConfig.from_pretrained(model_id).model_type
        cls = AutoModelForTDT if model_type == "parakeet_tdt" else AutoModelForCTC
        self.tdt = model_type == "parakeet_tdt"
        self.processor = AutoProcessor.from_pretrained(model_id)
        self.model = _load_checked(cls, model_id, dtype=self.torch_dtype).to(self.device).eval()
        self.load_seconds = time.perf_counter() - t0

    def transcribe(self, audios: list[np.ndarray]) -> list[str]:
        import torch

        with torch.inference_mode():
            inputs = self.processor(list(audios), sampling_rate=SR, return_tensors="pt")
            inputs = {
                k: (v.to(self.device, self.torch_dtype) if v.is_floating_point() else v.to(self.device))
                for k, v in inputs.items()
            }
            if self.tdt:
                seqs = self.model.generate(**inputs, return_dict_in_generate=True).sequences
            else:
                seqs = self.model(**inputs).logits.argmax(-1)
            return self.processor.batch_decode(seqs, skip_special_tokens=True)

    def info(self) -> dict:
        return {
            "class": type(self.model).__name__,
            "model_id": self.model_id,
            "device": self.device,
            "dtype": self.dtype,
            "load_seconds": round(self.load_seconds, 2),
        }


def _load_checked(cls, model_id: str, **kw):
    """from_pretrained, but refuse a checkpoint whose weights don't fully map."""
    m, info = cls.from_pretrained(model_id, output_loading_info=True, **kw)
    missing = sorted(info.get("missing_keys") or [])
    if missing:
        raise RuntimeError(
            f"{model_id}: {len(missing)} weights missing from checkpoint (e.g. {missing[0]}); "
            "refusing to serve a partially random model"
        )
    return m


def build(settings) -> Transcriber:
    if settings.fake_model:
        return FakeModel()
    return ParakeetModel(settings.model_id, settings.device, settings.dtype)

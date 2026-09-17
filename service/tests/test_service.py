"""No GPU, no weights: FAKE_MODEL=1. What is tested is the *service* - the
endpoints, readiness, audio handling, metrics - not the model."""

import io
import time

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from switchboard import app as app_module
from switchboard import config


def wav_bytes(seconds: float = 1.0, sr: int = 16_000, channels: int = 1) -> bytes:
    t = np.arange(int(sr * seconds)) / sr
    x = (0.2 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    if channels == 2:
        x = np.stack([x, x], axis=1)
    buf = io.BytesIO()
    sf.write(buf, x, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


@pytest.fixture
def client():
    settings = config.Settings(fake_model=True, max_audio_seconds=5.0)
    with TestClient(app_module.create_app(settings, load_in_background=False)) as c:
        yield c


def test_healthz_is_ok_immediately_even_before_the_model_loads():
    settings = config.Settings(fake_model=True)
    app = app_module.create_app(settings, load_in_background=True)
    with TestClient(app) as c:
        assert c.get("/healthz").json()["status"] == "ok"
        deadline = time.time() + 5
        while c.get("/readyz").status_code != 200 and time.time() < deadline:
            time.sleep(0.05)
        assert c.get("/readyz").json()["ready"] is True


def test_readyz_is_503_until_loaded_and_transcribe_refuses():
    settings = config.Settings(fake_model=True)
    app = app_module.create_app(settings, load_in_background=True)
    app.state.sb.load = lambda: None  # never loads
    with TestClient(app) as c:
        r = c.get("/readyz")
        assert r.status_code == 503 and r.json()["ready"] is False
        r = c.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(), "audio/wav")})
        assert r.status_code == 503


def test_transcribe_multipart_and_raw_body(client):
    r = client.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(1.5), "audio/wav")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["text"] == "fake transcript of 1.5 seconds"
    assert body["audio_seconds"] == pytest.approx(1.5)
    assert body["input_sample_rate"] == 16_000
    assert body["latency_ms"] >= 0 and "inference_ms" in body

    r = client.post("/v1/transcribe", content=wav_bytes(0.5), headers={"content-type": "audio/wav"})
    assert r.status_code == 200 and r.json()["text"] == "fake transcript of 0.5 seconds"


def test_phone_rate_audio_is_resampled_to_16k(client):
    r = client.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(2.0, sr=8_000), "audio/wav")})
    assert r.status_code == 200
    assert r.json()["input_sample_rate"] == 8_000
    assert r.json()["audio_seconds"] == pytest.approx(2.0)


def test_stereo_is_downmixed(client):
    r = client.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(1.0, channels=2), "audio/wav")})
    assert r.status_code == 200 and r.json()["audio_seconds"] == pytest.approx(1.0)


def test_bad_audio_and_too_long_are_400(client):
    assert client.post("/v1/transcribe", files={"file": ("a.wav", b"not audio", "audio/wav")}).status_code == 400
    assert client.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(6.0), "audio/wav")}).status_code == 400
    assert client.post("/v1/transcribe").status_code == 400


def test_metrics_expose_the_request_just_made(client):
    client.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(1.0), "audio/wav")})
    text = client.get("/metrics").text
    assert 'switchboard_requests_total{outcome="ok"}' in text
    assert "switchboard_request_seconds_bucket" in text
    assert "switchboard_queue_depth 0.0" in text
    assert "switchboard_in_flight 0.0" in text
    assert "switchboard_ready 1.0" in text
    assert 'switchboard_model_info{' in text and 'class="FakeModel"' in text


def test_fake_rtf_makes_the_fake_take_as_long_as_a_real_model():
    # FAKE_RTF is what lets scaling be proven without 3 GB pods: the fake holds
    # the inference lock for rtf x audio seconds, like the real model would.
    settings = config.Settings(fake_model=True, fake_rtf=0.4)
    with TestClient(app_module.create_app(settings, load_in_background=False)) as c:
        r = c.post("/v1/transcribe", files={"file": ("a.wav", wav_bytes(1.0), "audio/wav")})
    assert r.status_code == 200
    body = r.json()
    assert body["model"]["rtf"] == 0.4
    assert 380 <= body["inference_ms"] < 1000

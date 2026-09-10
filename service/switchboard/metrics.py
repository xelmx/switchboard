"""What the service reports about itself. Every name starts with `switchboard_`.

A histogram for latency (not an average): Prometheus can compute p50/p95/p99
from the buckets later, and a load test is judged on p95, never on the mean.
"""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, Info

REQUESTS = Counter("switchboard_requests_total", "Transcription requests", ["outcome"])
LATENCY = Histogram(
    "switchboard_request_seconds",
    "End-to-end request time, decode + queue + inference",
    buckets=(0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 5, 8, 13, 20),
)
INFERENCE = Histogram(
    "switchboard_inference_seconds",
    "Model time only",
    buckets=(0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 3, 5, 8),
)
QUEUE_WAIT = Histogram(
    "switchboard_queue_wait_seconds",
    "Time a request waited for the inference lock",
    buckets=(0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
IN_FLIGHT = Gauge("switchboard_in_flight", "Requests currently inside the service")
QUEUE_DEPTH = Gauge("switchboard_queue_depth", "Requests waiting for the inference lock")
AUDIO_SECONDS = Counter("switchboard_audio_seconds_total", "Seconds of audio transcribed")
MODEL_LOAD = Gauge("switchboard_model_load_seconds", "How long the model took to load")
READY = Gauge("switchboard_ready", "1 when the model is loaded and serving")
MODEL = Info("switchboard_model", "Which model is serving")

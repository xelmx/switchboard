"""The service.

Startup: the process starts listening immediately; the model loads in a
background thread. `/healthz` answers "ok" from the first millisecond
(liveness: is the process alive?); `/readyz` answers false until the weights
are loaded (readiness: can it take traffic?). Kubernetes uses the first to
decide whether to restart the container and the second to decide whether to
send it requests - a model server needs both, because it is alive for ~30 s
before it is useful.

Inference: one lock. The GPU is the serialisation point; concurrent requests
wait their turn, and how many are waiting (`switchboard_queue_depth`) is the
number scaling will key off later. The model call runs in a worker thread so
the event loop keeps answering health checks while the GPU is busy.
"""

from __future__ import annotations

import asyncio
import logging
import threading
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from . import __version__, audio, config, metrics, model

log = logging.getLogger("switchboard")


class State:
    def __init__(self, settings: config.Settings):
        self.settings = settings
        self.model: model.Transcriber | None = None
        self.load_error: str | None = None
        self.lock = asyncio.Lock()
        self.started = time.time()

    def load(self) -> None:
        try:
            m = model.build(self.settings)
        except Exception as e:  # keep the process alive so the failure is observable
            self.load_error = f"{type(e).__name__}: {e}"
            log.exception("model load failed")
            return
        metrics.MODEL_LOAD.set(m.load_seconds)
        metrics.MODEL.info({k: str(v) for k, v in m.info().items()})
        metrics.READY.set(1)
        self.model = m
        log.info("model ready in %.1fs: %s", m.load_seconds, m.info())


def create_app(settings: config.Settings | None = None, load_in_background: bool = True) -> FastAPI:
    settings = settings or config.load()
    state = State(settings)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        # Startup: begin loading the model, but do not wait for it - the server must
        # answer /healthz immediately, and /readyz says when it can take traffic.
        if load_in_background:
            threading.Thread(target=state.load, name="model-load", daemon=True).start()
        else:
            state.load()
        yield

    app = FastAPI(title="switchboard", version=__version__, lifespan=lifespan)
    app.state.sb = state

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok", "uptime_seconds": round(time.time() - state.started, 1)}

    @app.get("/readyz")
    async def readyz():
        if state.model is not None:
            return {"ready": True, "model": state.model.info()}
        body = {"ready": False, "error": state.load_error}
        return JSONResponse(body, status_code=503)

    @app.get("/metrics")
    async def metrics_endpoint():
        return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post("/v1/transcribe")
    async def transcribe(request: Request, file: UploadFile | None = File(default=None)):
        t_start = time.perf_counter()
        metrics.IN_FLIGHT.inc()
        try:
            if state.model is None:
                metrics.REQUESTS.labels("not_ready").inc()
                raise HTTPException(503, "model not loaded" + (f": {state.load_error}" if state.load_error else ""))
            data = await file.read() if file is not None else await request.body()
            if not data:
                metrics.REQUESTS.labels("bad_request").inc()
                raise HTTPException(400, "send audio as multipart field 'file' or as the raw request body")
            try:
                x, sr = audio.decode(data, settings.max_audio_seconds)
            except audio.BadAudio as e:
                metrics.REQUESTS.labels("bad_request").inc()
                raise HTTPException(400, str(e)) from e

            t_queue = time.perf_counter()
            metrics.QUEUE_DEPTH.inc()
            acquired = False
            try:
                async with state.lock:
                    metrics.QUEUE_DEPTH.dec()
                    acquired = True
                    metrics.QUEUE_WAIT.observe(time.perf_counter() - t_queue)
                    t_inf = time.perf_counter()
                    (text,) = await run_in_threadpool(state.model.transcribe, [x])
                    inference_s = time.perf_counter() - t_inf
            finally:
                if not acquired:  # cancelled or failed while still waiting in the queue
                    metrics.QUEUE_DEPTH.dec()
            metrics.INFERENCE.observe(inference_s)
            metrics.AUDIO_SECONDS.inc(len(x) / model.SR)
            metrics.REQUESTS.labels("ok").inc()
            latency_s = time.perf_counter() - t_start
            metrics.LATENCY.observe(latency_s)
            return {
                "text": text,
                "audio_seconds": round(len(x) / model.SR, 3),
                "input_sample_rate": sr,
                "latency_ms": round(latency_s * 1000, 1),
                "inference_ms": round(inference_s * 1000, 1),
                "model": state.model.info(),
            }
        except HTTPException:
            raise
        except Exception as e:
            metrics.REQUESTS.labels("error").inc()
            log.exception("transcription failed")
            raise HTTPException(500, f"{type(e).__name__}: {e}") from e
        finally:
            metrics.IN_FLIGHT.dec()

    return app


app = create_app()


def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    s = config.load()
    uvicorn.run("switchboard.app:app", host="0.0.0.0", port=s.port, workers=1, log_level="info")

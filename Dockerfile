# syntax=docker/dockerfile:1.7
#
# switchboard: Parakeet-TDT speech-to-text as a service.
#
#   docker build -t switchboard:dev .
#   docker run --rm --gpus all -p 8000:8000 switchboard:dev                 # GPU
#   docker run --rm -e DEVICE=cpu -p 8000:8000 switchboard:dev              # CPU
#
# Two stages. The builder installs Python packages and downloads the model
# weights; the runtime copies only the results. Weights are baked in, pinned to
# a revision, so a container's cold start is a property of the image - not of
# the network on the day.

ARG PYTHON=3.12
ARG MODEL_ID=nvidia/parakeet-tdt-0.6b-v3
# Pinned: the commit on the Hub as of 2026-09-10. Change deliberately, never "main".
ARG MODEL_REVISION=541d1f99c6b0c3cd0b11a95167540bb8edefd82b

# ---------------------------------------------------------------- builder ----
FROM ubuntu:24.04 AS builder
ARG PYTHON MODEL_ID MODEL_REVISION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      python${PYTHON} python${PYTHON}-venv ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /usr/local/bin/uv

# 1. Python environment: exactly the locked dependency set, no dev tools.
WORKDIR /app
COPY service/pyproject.toml service/uv.lock ./
ENV UV_PROJECT_ENVIRONMENT=/opt/venv UV_PYTHON=/usr/bin/python${PYTHON} UV_LINK_MODE=copy
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# 2. Model weights: exactly the transformers-format files, named one by one, pinned.
#    (`hf download` treats bare arguments after the repo as the files to fetch -
#    a glob pattern there is a filename, not a filter. Name them; never rely on
#    --exclude.) The .nemo and .gguf copies of the same model are not shipped.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv tool run --from 'huggingface_hub[cli]' hf download "${MODEL_ID}" \
      config.json generation_config.json model.safetensors \
      processor_config.json tokenizer.json tokenizer_config.json \
      --revision "${MODEL_REVISION}" --local-dir /models/parakeet \
    && rm -rf /models/parakeet/.cache \
    && ls -la /models/parakeet \
    && grep -q '"model_type": "parakeet_tdt"' /models/parakeet/config.json

# 3. The service itself, last: it changes most often, so its layer is cheapest to rebuild.
COPY service/switchboard /app/switchboard

# ---------------------------------------------------------------- runtime ----
# CUDA "base" image: driver stubs and nothing else (~100 MB). torch's own wheels
# carry the CUDA libraries it needs; the host's NVIDIA driver is mounted in by the
# container runtime (`--gpus all`).
FROM nvidia/cuda:12.8.0-base-ubuntu24.04 AS runtime
ARG PYTHON MODEL_ID MODEL_REVISION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      python${PYTHON} libsndfile1 curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 app

COPY --from=builder --chown=app:app /opt/venv /opt/venv
COPY --from=builder --chown=app:app /models/parakeet /models/parakeet
COPY --from=builder --chown=app:app /app/switchboard /app/switchboard

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    MODEL_ID=/models/parakeet \
    DEVICE=auto \
    DTYPE=auto \
    PORT=8000 \
    HF_HUB_OFFLINE=1
LABEL org.opencontainers.image.source="https://github.com/xelmx/switchboard" \
      switchboard.model="${MODEL_ID}@${MODEL_REVISION}"

USER app
WORKDIR /app
EXPOSE 8000
# Liveness only: Kubernetes will ask /readyz itself. Docker's healthcheck is for `docker run`.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -sf http://localhost:8000/healthz || exit 1
CMD ["python3", "-m", "switchboard.app"]

#!/usr/bin/env bash
# Run anything in the service's environment from inside WSL Ubuntu.
#
#   scripts/sb.sh pytest -q                 # tests, no GPU
#   scripts/sb.sh switchboard               # start the service on :8000
#   scripts/sb.sh python -c "import torch; print(torch.cuda.is_available())"
#
# The virtualenv lives on the Linux disk (~/.venvs/switchboard), not under the
# slow /mnt/c mount, and uv copies rather than hard-links across filesystems.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export UV_PROJECT_ENVIRONMENT="$HOME/.venvs/switchboard"
export UV_LINK_MODE=copy
# Default model location for local development: the weights already on the Windows disk.
export MODEL_ID="${MODEL_ID:-/mnt/c/Users/lyle/Projects/models/stt/parakeet-tdt-0.6b-v3}"
cd "$(dirname "$0")/../service"
exec uv run "$@"

# syntax=docker/dockerfile:1.7
#
# Deterministic + cache-friendly + CUDA-capable ebook2audiobook build.
#
# Notes on determinism:
# - CUDA base is pinned by digest.
# - uv and Python are pinned by version.
# - torch/vision/audio are pinned to a known matching cu121 trio per PyTorch docs.
# - apt and pip ecosystems are not fully reproducible over time unless you also lock/snapshot repos.

######################################################################
# Runtime image (CUDA devel + pinned Python stack)
######################################################################
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04@sha256:7012e535a47883527d402da998384c30b936140c05e2537158c80b8143ee7425

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Predictable cache locations (and writable later by non-root user)
ENV XDG_CACHE_HOME=/opt/cache \
    HF_HOME=/opt/cache/huggingface \
    TRANSFORMERS_CACHE=/opt/cache/huggingface/transformers \
    TORCH_HOME=/opt/cache/torch \
    STANZA_RESOURCES_DIR=/opt/cache/stanza

# uv cache (bind-mount at runtime to persist wheels/downloads)
ENV UV_CACHE_DIR=/opt/cache/uv \
    UV_PYTHON_DOWNLOADS=1

# If set to 1, container exits immediately if CUDA isn't usable.
ENV E2A_REQUIRE_CUDA=1

######################################################################
# System deps (cache-friendly apt)
######################################################################
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      tini \
      bzip2 \
      ffmpeg \
      calibre \
      mecab \
      mecab-ipadic \
      libmecab-dev \
      libglib2.0-0 \
      libsm6 \
      libxext6 \
      libxrender1 \
 && apt-get clean

######################################################################
# Python env: pin Python + pip versions (single source of truth for env)
######################################################################
ARG PYTHON_VERSION="3.12.4"
ARG PIP_VERSION="24.2"
ARG VENV_DIR="/opt/venv"

# Pin build tooling too (these otherwise float)
ARG SETUPTOOLS_VERSION="75.1.0"
ARG WHEEL_VERSION="0.44.0"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="/root/.local/bin:${VENV_DIR}/bin:${PATH}"

RUN --mount=type=bind,source=/drive/cache/dot-cache/uv,target=/opt/cache/uv \
    uv python install "${PYTHON_VERSION}" \
 && uv venv "${VENV_DIR}" --python "${PYTHON_VERSION}" \
 && uv pip install --python "${VENV_DIR}/bin/python" \
      "pip==${PIP_VERSION}" \
      "setuptools==${SETUPTOOLS_VERSION}" \
      "wheel==${WHEEL_VERSION}"

######################################################################
# App source: copy only requirements.txt first for maximum caching
######################################################################
WORKDIR /app/ebook2audiobook
COPY requirements.txt /app/ebook2audiobook/requirements.txt

######################################################################
# Torch/CUDA: pin known-compatible cu121 trio (official PyTorch guidance)
######################################################################
ARG TORCH_VER="2.4.1"
ARG TORCHVISION_VER="0.19.1"
ARG TORCHAUDIO_VER="2.4.1"
ARG TORCH_INDEX_URL="https://download.pytorch.org/whl/cu121"

RUN printf "%s\n" \
    "torch==${TORCH_VER}" \
    "torchvision==${TORCHVISION_VER}" \
    "torchaudio==${TORCHAUDIO_VER}" \
    > /tmp/constraints.txt

# Install torch trio first (then forbid pip from changing it via constraints)
RUN --mount=type=bind,source=/drive/cache/dot-cache/uv,target=/opt/cache/uv \
    uv pip install --python "${VENV_DIR}/bin/python" \
      "torch==${TORCH_VER}" \
      "torchvision==${TORCHVISION_VER}" \
      "torchaudio==${TORCHAUDIO_VER}" \
      --index-url "$TORCH_INDEX_URL"

RUN --mount=type=bind,source=/drive/cache/dot-cache/uv,target=/opt/cache/uv \
    uv pip install --python "${VENV_DIR}/bin/python" \
      --constraint /tmp/constraints.txt \
      --prefer-binary \
      --extra-index-url "$TORCH_INDEX_URL" \
      -r requirements.txt

# Build-time check: confirms CUDA-flavored wheels were installed (no GPU needed at build time)
RUN "${VENV_DIR}/bin/python" -c "\
import torch; \
print('torch', torch.__version__); \
print('torch.version.cuda', torch.version.cuda); \
assert torch.version.cuda and str(torch.version.cuda).startswith('12.1') \
"

######################################################################
# Now copy the full app repo (late, so code edits don't bust dependency cache)
######################################################################
COPY . /app/ebook2audiobook

# CUDA runtime preflight: fail loud, no silent CPU fallback
######################################################################
RUN cat > /usr/local/bin/e2a_cuda_preflight.py <<'PY'
import os, sys

req = os.environ.get('E2A_REQUIRE_CUDA', '1') not in ('0','false','False','no','NO')

import torch
ok = torch.cuda.is_available()

print('torch.__version__ =', torch.__version__)
print('torch.version.cuda =', torch.version.cuda)
print('torch.cuda.is_available() =', ok)
print('torch.cuda.device_count() =', torch.cuda.device_count())

if ok:
    x = torch.zeros((1,), device='cuda')
    print('CUDA tensor alloc OK:', x)
    print('cuda device 0 name:', torch.cuda.get_device_name(0))
else:
    if req:
        print('FATAL: CUDA not available inside container. Check host driver + NVIDIA Container Toolkit.', file=sys.stderr)
        sys.exit(2)
PY
######################################################################
# Non-root runtime user (and make caches writable)
######################################################################
RUN useradd -m -u 1000 user \
 && mkdir -p /opt/cache \
 && chown -R user:user /app /opt/cache

USER user

EXPOSE 7860
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash", "-lc", "\"/opt/venv/bin/python\" /usr/local/bin/e2a_cuda_preflight.py && \"/opt/venv/bin/python\" app.py --server_name 0.0.0.0 --port 7860"]

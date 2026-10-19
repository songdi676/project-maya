# syntax=docker/dockerfile:1
#
# Project Maya: GLM-5.3-Flash on NVIDIA GPUs (RTX 20 and newer; one card or up
# to sixteen sharing the model). The model itself is ~95-160 GB, so the /data
# volume wants a fast disk and the host the RAM (32 GB runs it, more is faster).
#
# The engine is compiled during docker build, so the first container start only
# downloads the model, builds the pack and starts the server. docker build has
# no GPU, so the CUDA architectures are fixed here instead of read from
# nvidia-smi: the engine is a fat binary with a cubin per listed arch, and the
# runtime picks the one matching your card. Narrow CUDA_ARCHITECTURES to your
# card for a faster build; a card outside the set needs a rebuild with its own
# arch. The image's CUDA 13 cannot build for Volta (sm_70): a V100 host runs the
# native install with CUDA 12.x instead (docs/SETUP.md).
#
# Build:
#   docker build -t maya .
#   docker build -t maya --build-arg CUDA_ARCHITECTURES=89 .        # RTX 40 only
#   docker build -t maya --build-arg BUILD_VISION=0 .               # text only
#
# Run (host needs an NVIDIA driver >= 580 and nvidia-container-toolkit):
#   docker run --rm --gpus all \
#     -p 8080:8080 \
#     --ulimit memlock=-1 \
#     --stop-timeout 60 \
#     -v maya-data:/data \
#     -e MODEL=Maya-S24 \
#     maya
#
# Setup choices are env vars, read by docker-entrypoint.sh: MODEL
# (Maya-S-v2-IQ2_XXS | Maya-S24 | Maya-M | Maya-M-Derisked | Maya-L |
# EXL3-3.05bpw), CONTEXT, VISION (yes | no), DRAFT (mtp | dflash2), GPU (one
# card) or GPUS ("0,1": one model across several cards), GGUF_DIR (GGUF files
# you already have), RAM_HEADROOM_GB, HOST, PORT, API_KEY, CONFIG, REINSTALL.
#
# Only the model files, the pack, the vision files and the install config live
# in the /data volume; the engine is part of the image, in build/strata and
# build-vision/bin/strata-vision - exactly where the config points, so those
# trees stay. Maya pins most of the free RAM for its expert tier, and inside a
# container it measures the host's RAM, not the container's limit: a memory-
# capped container sets its own headroom with -e RAM_HEADROOM_GB. Add an API key
# before exposing the port to a network: -e API_KEY=<secret>. Pass -e REINSTALL=1
# to change the model settings later.
#
# --gpus all on a host with several cards: the setup takes them all (the layer
# split across them is its default). Pin one card with -e GPU=0, or name them
# with -e GPUS=0,1.

FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 \
        python3 python3-pip python3-venv unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/maya
COPY . .

# RTX 20 (75), A-series (80), RTX 30 (86), RTX 40 (89), RTX 50 (120). CMakeLists
# refuses anything below 75 (Maya's own floor; the V100 note above). BUILD_VISION=0
# skips the image encoder build.
ARG CUDA_ARCHITECTURES=75;80;86;89;120
ARG BUILD_VISION=1

RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && chmod +x setup.sh maya.sh docker-entrypoint.sh

# llama.cpp at the pinned commit, then the engine and the image encoder, built
# exactly the way maya.py builds them: its own compile_engine / compile_vision,
# so the MAYA-BUILD.json stamps they write are in place and the first start
# reuses the engine instead of recompiling (the source hash matches the source
# in this image). Native code for the CPU that builds the image, so build it on
# the PC it runs on.
RUN .venv/bin/python - <<'PYEOF'
import os, sys
import maya
import setup as S

archs = [int(a) for a in os.environ.get("CUDA_ARCHITECTURES", "75;80;86;89;120")
         .strip().strip('"').replace(",", ";").split(";") if a.strip().isdigit()]
S.pip_install(S.PY_PACKAGES, "the Python packages")
llama = S.get_llama_cpp()
nvcc, _ = maya.find_nvcc(archs)
if nvcc is None:
    sys.exit("no CUDA toolkit (nvcc) in the image - the nvidia/cuda devel base should provide it")
meta = maya.compile_engine(archs, [0], nvcc, None, llama, S.source_hash(S.ENGINE_SOURCES))
if meta is None:
    sys.exit("the engine build stopped")
if os.environ.get("BUILD_VISION", "1") == "1":
    if not maya.compile_vision({"backend": "cuda", "archs": archs, "nvcc": nvcc}, meta, llama,
                               S.source_hash(("tools/vision",))):
        sys.exit("the vision encoder build stopped")
PYEOF

# the pip cache is build-time only (S.pip_install's own pip run)
RUN rm -rf /root/.cache/pip

VOLUME ["/data"]
EXPOSE 8080

# /health is answered before the API key gate, so it works with or without one.
# The port only opens after the model loads (a few minutes; the first start also
# downloads ~95-160 GB and builds the pack), so the start period is generous: a
# too short one marks a still-loading container unhealthy and a restart policy
# would kill it mid-download.
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fs "http://127.0.0.1:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]

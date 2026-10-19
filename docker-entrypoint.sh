#!/bin/sh
# Entry point for the Maya container. The engine is compiled during docker build
# and lives in the image (build/strata, where the config points), so the first
# start only downloads the model and builds the pack. The install config is kept
# on the /data volume so a recreated container skips the setup pass and goes
# straight to serving.
set -e
cd /opt/maya || exit 1

# The engine's CPU lane runs AVX2 kernels. A host CPU without AVX2 (Sandy / Ivy
# Bridge Xeons, Bulldozer) runs it into an illegal instruction. A warning, not a
# stop: recommend, never force (the flags file can be wrong in a VM, and a build
# made on that host may be fine). MAYA_CPUINFO is for the test.
cpuinfo="${MAYA_CPUINFO:-/proc/cpuinfo}"
if [ -r "$cpuinfo" ] && grep -q '^flags' "$cpuinfo" && ! grep -m1 '^flags' "$cpuinfo" | grep -qw avx2; then
  echo "WARNING: this host CPU has no AVX2. The engine in this image is built for CPUs with AVX2, so it may stop" >&2
  echo "  with 'illegal instruction' (exit 132). Build the image on this machine (docker build), which compiles the" >&2
  echo "  engine for the CPU it runs on." >&2
fi

# The image carries a cubin per CUDA architecture it was built for (the archs in
# build/MAYA-BUILD.json). A card outside that set cannot run it. A warning, not
# a stop: docker build --build-arg CUDA_ARCHITECTURES=<arch> on this machine
# fixes every arch CUDA 13 can build; the V100 (sm_70) needs the native install
# with CUDA 12.x, which this image cannot be.
if command -v nvidia-smi >/dev/null 2>&1 && [ -r build/MAYA-BUILD.json ]; then
  .venv/bin/python - <<'PYEOF' || true
import json, subprocess, sys
try:
    archs = set(json.load(open("build/MAYA-BUILD.json")).get("archs") or [])
except Exception:
    sys.exit(0)
r = subprocess.run(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"],
                   capture_output=True, text=True)
if r.returncode:
    sys.exit(0)
caps = {int(round(float(c) * 10)) for c in r.stdout.split() if c.strip()}
missing = sorted(caps - archs)
if not missing:
    sys.exit(0)
print("WARNING: this host has a GPU with compute capability " +
      ", ".join(f"{c / 10:.1f}" for c in missing) + ", but the engine in this image was built only for " +
      (", ".join(f"{a / 10:.1f}" for a in sorted(archs)) if archs else "no listed arch") + ".", file=sys.stderr)
if 70 in missing:
    print("  CUDA 13 (this image) cannot build for Volta: a V100 runs the native install with CUDA 12.x"
          " (docs/SETUP.md), not this image.", file=sys.stderr)
else:
    print("  Rebuild the image for it: docker build --build-arg CUDA_ARCHITECTURES=<arch> .", file=sys.stderr)
PYEOF
fi

MAYA_DATA="${MAYA_DATA:-/data}"
MODEL="${MODEL:-Maya-S-v2-IQ2_XXS}"
CONTEXT="${CONTEXT:-32768}"
VISION="${VISION:-yes}"          # yes | no (the image encoder and its 1.1 GB of files)
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
API_KEY="${API_KEY:-}"
GPUS="${GPUS:-}"                 # "0,1": one model across several cards
GPU="${GPU:-}"                   # one card, numbered as nvidia-smi numbers them
DRAFT="${DRAFT:-}"               # mtp | dflash2; empty: maya.py's own default (mtp)
GGUF_DIR="${GGUF_DIR:-}"         # a mounted folder with GGUF files you already have: no download
RAM_HEADROOM_GB="${RAM_HEADROOM_GB:-}"   # RAM the engine leaves free; in a container its RAM measure is the
                                         # host's, not the cgroup limit, so a capped container names it here
CONFIG="${CONFIG:-}"             # a config file to start with (wins over MODEL's /data/config/maya-<model>.json)

# maya.py starts the newest maya-*.json it finds and names it after the quant in
# lowercase, so link in exactly the one this model was set up with. The config is
# the recorded output of that setup (the pack, the GPUs, the context, the vision
# decision), not settings the entry point could rebuild from env vars.
tag=$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')
cfg="$MAYA_DATA/config/maya-$tag.json"
link="/opt/maya/maya-$tag.json"
mkdir -p "$MAYA_DATA/config"

# REINSTALL is only needed to change settings for a model that is already set up
# (context, vision, host, api_key, GPUs, draft). Switching between models already
# on the volume needs no setup pass: their config is already there.
#
# GPU / GPUS are passed only when set, so an unset one keeps maya.py's own pick
# (every card the container sees).
keep=""
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "CONFIG=$CONFIG does not exist." >&2; exit 1; }
elif [ "${REINSTALL:-0}" != "1" ] && [ -L "$link" ] && [ -f "$link" ]; then
  case "$(readlink "$link")" in "$MAYA_DATA"/config/*) keep=1 ;; esac
fi

if [ -n "$CONFIG" ]; then
  ln -sfn "$CONFIG" "$link"
  echo "Config: $CONFIG (from CONFIG)"
elif [ -n "$keep" ]; then
  echo "Config: $(readlink "$link") (existing link kept)"
elif [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  if [ -n "$GGUF_DIR" ]; then
    echo "Setting up $MODEL from the GGUF files in $GGUF_DIR (the engine is already in the image)."
  else
    echo "Setting up $MODEL: downloading the model (~95-160 GB; the engine is already in the image)."
  fi
  set -- --setup --yes --model "$MODEL" --context "$CONTEXT" --models-dir "$MAYA_DATA/models" \
    --host "$HOST" --port "$PORT" --api-key "$API_KEY" --no-start
  if [ "$VISION" = "no" ]; then set -- "$@" --no-vision; fi
  if [ -n "$GPUS" ]; then set -- "$@" --gpus "$GPUS"; fi
  if [ -n "$GPU" ]; then set -- "$@" --gpu "$GPU"; fi
  if [ -n "$DRAFT" ]; then set -- "$@" --draft "$DRAFT"; fi
  if [ -n "$GGUF_DIR" ]; then set -- "$@" --gguf-dir "$GGUF_DIR"; fi
  if [ -n "$RAM_HEADROOM_GB" ]; then set -- "$@" --env "STRATA_GLM_RAM_HEADROOM_GB=$RAM_HEADROOM_GB"; fi
  .venv/bin/python maya.py "$@"
  [ -e "$link" ] && { cmp -s "$link" "$cfg" || cp -f "$link" "$cfg"; }
  echo "Config: $cfg (from MODEL $MODEL, just set up)"
else
  # the copy on the volume is the one that counts, so a regular file left in
  # /opt/maya by an earlier setup (or by an image built with one) must not stand
  # in for it: edits to /data/config would be ignored
  ln -sfn "$cfg" "$link"
  echo "Config: $cfg (from MODEL $MODEL)"
fi

# Later starts skip straight here: the server (OpenAI- and Anthropic-compatible
# API plus the dashboard on :$PORT) starts from the installed config. It is
# exec'd as PID 1, not through maya.py: docker stop's SIGTERM then reaches the
# server itself, which gives its engine QUIT and time to keep its conversation
# (maya.py would start the server as a child and take the signal alone).
# GPU / GPUS are repeated on purpose: given at the start they pin the cards for
# this run, over what the config recorded.
set -- --engine strata --config "$link" --port "$PORT" --host "$HOST"
if [ -n "$API_KEY" ]; then set -- "$@" --api-key "$API_KEY"; fi
if [ -n "$GPUS" ]; then set -- "$@" --gpu "$GPUS"; fi
if [ -n "$GPU" ]; then set -- "$@" --gpu "$GPU"; fi
exec .venv/bin/python serve/server.py "$@"

# Setting up Maya

The setup in detail: what its first run does, starting again and updating, and its options. Back to the
[README](../README.md).

## What the first run does

It takes 20-40 minutes plus the download:

1. checks the PC (GPUs, driver, CUDA toolkit, compiler, RAM, CPU);
2. asks which GPUs to use (all of them by default, up to 16), how much context (32K recommended), which model to
   download: Maya-S (recommended; Maya-S24 on cards of 24 GB or less), Maya-M, Maya-M-Derisked or Maya-L, and how it
   drafts: the model's MTP block (the default) or a [DFlash2 drafter](SETTINGS.md#drafting-with-dflash2) (NVIDIA RTX
   30 / A100 and newer);
3. installs its Python packages into `.venv` and gets llama.cpp's source at a pinned commit (it lists both and asks);
4. compiles the engine for your GPU(s) (10-30 minutes, once);
5. **the model**: it shows the source, the size (Maya-S: 96.5 GB) and the exact `curl` commands, and downloads only
   when you answer `y`; every file is checked against its published sha256. You can run the commands yourself
   instead, or use files you already have: `./maya.sh --gguf-dir DIR` - other quants than these four are
   experimental: they run, but Maya is not measured with them. With DFlash2 it also downloads the drafter (0.7 GB,
   checked against its sha256) next to the models;
6. builds the *pack* - the engine's index of the model files, about 1 GB, written into the model folder. A Maya
   model's files that were already there are checked against their sha256 first (once each); the pack records the
   files, and a start refuses it if they change afterwards (`--repack` builds it again);
7. **pictures**: compiles the image encoder (10-20 minutes, once) and fetches its files (1.1 GB, shown and asked
   first); `--no-vision` skips it;
8. writes `maya-<model>.json` and `run-maya-<model>.sh`; with DFlash2 it runs the
   [speed calibration](SETTINGS.md#the-speed-calibration) (5-20 minutes: DFlash2 stays only if it is faster on your
   PC); then the settings [tuned for this PC](SETTINGS.md) earlier, or it offers the tuning (about 10-15 minutes;
   `./maya.sh --calibrate` any time) - and starts the dashboard.

> **The start takes a few minutes**: the engine pins most of the free RAM (all but about 6 GB) for its expert tier
> and warms its caches. Other programs get little RAM while Maya runs.

## Next time, and updating

**Next time**, just run `./setup.sh` again (or the model's `./run-maya-<model>.sh`): it starts right away, nothing is
downloaded twice, on the same screen - its dashboard shows the Monitor's numbers (the speed, where the experts live, the
GPUs, the requests), Tab its log. Ctrl+C stops it.

**Updating:** the dashboard's **About** says when a new version is out, and its **Update** button does it: Maya
downloads the new code (git), compiles only the engine files that changed and loads the same model again - the model
is not downloaded again, and your settings stay. By hand: `git pull`, then `./setup.sh`.
(The check asks GitHub for the latest release, at most every six hours; `MAYA_UPDATE_CHECK=0` turns it off.)

## Docker (Linux)

The same idea, in a container (NVIDIA cards).

1. Host: Docker with the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
   and a driver **580 or newer** (CUDA 13.0).
2. Build (this compiles the engine into the image, so the container never compiles):
   `docker build -t maya .`
   `docker build -t maya --build-arg CUDA_ARCHITECTURES=89 .` builds for one card only (faster).
   The default covers RTX 20 (75), A-series (80), RTX 30 (86), RTX 40 (89) and RTX 50 (120); a card
   outside that set needs a rebuild with its own arch. The image's CUDA 13 cannot build for the V100
   (sm_70) - a V100 host runs the native install above with CUDA 12.x. Add `--build-arg BUILD_VISION=0`
   to skip the image encoder.
3. Run (the first start downloads the model - 95-160 GB by quant - builds the pack and starts; later
   starts go straight to serving):

   ```sh
   docker run --rm --gpus all -p 8080:8080 --ulimit memlock=-1 --stop-timeout 60 \
     -v maya-data:/data -e MODEL=Maya-S24 maya
   ```

   The setup choices are env vars: `-e MODEL=Maya-S24` (`Maya-S-v2-IQ2_XXS` (the default) | `Maya-S24`
   | `Maya-M` | `Maya-M-Derisked` | `Maya-L` | `EXL3-3.05bpw`), `-e CONTEXT=32768`, `-e VISION=no`,
   `-e DRAFT=dflash2`, `-e GPU=0` or `-e GPUS=0,1` (the layer split), `-e GGUF_DIR=/models` (GGUF files
   you already have, mounted), `-e RAM_HEADROOM_GB=16`, `-e HOST`, `-e PORT`, `-e API_KEY`.
   Only the model files, the pack, the vision files and the install config live in the `maya-data`
   volume; the engine is part of the image. Switching between models already on the volume needs no
   setup pass: `-e MODEL=Maya-M` picks that model's config. Add `-e REINSTALL=1` only to change
   settings for a model already set up (context, vision, host, api_key, GPUs, draft). `MODEL` selects
   `/data/config/maya-<model>.json` (the model name in lowercase); `-e CONFIG=/data/config/my.json`
   overrides it with any config file.
   Maya pins most of the free RAM for its expert tier, and inside a container it measures the **host's**
   RAM, not the container's limit: a memory-capped container names its own headroom with
   `-e RAM_HEADROOM_GB`. Add an API key before exposing the port to a network: `-e API_KEY=<secret>`.
4. `docker stop` gives the server 10 seconds by default; a request in progress gets longer to close and
   answer: `docker run --stop-timeout 60 ...`, `docker stop -t 60 <name>`, or
   `stop_grace_period: 60s` in Compose.

## Options

| Option | |
| --- | --- |
| `--setup` | set up again (other GPUs, context, model folder) |
| `--check` | only check the PC |
| `--gguf-dir DIR` | use GLM-5.3-Flash GGUF files you already have: their folder, or the `.gguf` file (the first one of a split model) when the folder holds several models. The folder must be writable: the pack goes inside it |
| `--models-dir DIR` | where downloaded models go, each in a folder named after it - `DIR/Maya-L/` holds that model's GGUF files (default `../Maya-data/models`); put it on the NVMe |
| `--download-model` | download the model without asking (the commands and size are still printed) |
| `--model NAME` | which model, without asking: `Maya-S-v2-IQ2_XXS` (Maya-S), `Maya-S24`, `Maya-M`, `Maya-M-Derisked`, `Maya-L`, or `EXL3-3.05bpw` - an experimental EXL3 quant at 3.05 bits per weight ([on Hugging Face](https://huggingface.co/turboderp/GLM-5.3-Flash-exl3/tree/3.05bpw), 125.3 GB, with the MTP block) that the engine reads in place from its safetensors: NVIDIA only, tested on Linux, not measured against the FP8 model |
| `--no-vision` | text only: no image encoder |
| `--draft mtp` / `--draft dflash2` | how the model drafts tokens ahead: its MTP block (the default), or a DFlash2 drafter - downloaded (0.7 GB) into `DIR/GLM-5.3-Flash-DFlash2/` and passed as `--dflash` (Maya-L: +44% on nine GPUs, +12% on two, +19% on one GPU; NVIDIA RTX 30 / A100 and newer - older cards keep the MTP block unless you pass this; the drafter's license is CC BY-NC-ND 4.0, non-commercial use only). The [speed calibration](SETTINGS.md#the-speed-calibration) then keeps it only if it is faster on your PC |
| `--gpu N` / `--gpus 0,1,2,3` | one GPU, or several (up to 16) that split the model's layers |
| `--context N` | context length in tokens: 8192, 32768 (default), 65536, 131072 |
| `--port N`, `--host 0.0.0.0 --api-key KEY` | another port; reachable from your network (always set a key; several: `KEY1,KEY2`) |
| `--env KEY=VALUE` | an engine setting kept in the config (see [Tuning](SETTINGS.md)) |
| `--host-compiler g++-12` | when your g++ is newer than your CUDA accepts ("unsupported GNU version") |
| `--rebuild`, `--repack` | compile the engine / build the pack again |
| `--calibrate` | tune the engine's CPU lane for this PC (see [Tuning](SETTINGS.md)), then start; with `--no-start` only tune |
| `--speed-calibration` | measure again whether DFlash2 or the MTP block decodes faster on this PC ([how](SETTINGS.md#the-speed-calibration); 5-20 minutes, with Maya stopped) and keep the faster, then start; with `--no-start` only measure |
| `--no-speed-calibration` | with `--draft dflash2`: keep DFlash2 without the speed calibration |
| `--yes` | the recommended answers (the model download still needs `--download-model`) |
| `--plain` | the setup in plain text with typed answers, and Maya in the terminal, not on their own screen (a pipe gets this too, and `--yes` a plain setup); the setup screen's whole output is in `maya-setup.log` |

## Web pages on another address

A browser stops a web page served from another address (a local chat client on `http://127.0.0.1:8090`, say) from
calling Maya's API unless Maya allows that page. List the pages in the config, `maya-<model>.json`:

```json
"cors_origins": ["http://127.0.0.1:8090"]
```

Exact addresses (scheme, host and port, no path); `["*"]` lets every page in - set an `api_key` with it, or any page
you open could use your model. It opens `/v1/*` and nothing else: the settings and the tools stay for Maya's own page.
Without it nothing changes. A new `--setup` writes the config again: add the line back after it.

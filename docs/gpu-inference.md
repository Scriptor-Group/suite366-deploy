# On-host GPU inference (vLLM)

When an NVIDIA GPU is present, Suite 366 can run its LLM **entirely on your own
GPU** — no external API, nothing leaves the machine. The installer deploys **two**
vLLM instances as host Docker services (outside k3s), each exposing an
OpenAI-compatible API:

| Service              | Default model                 | Host port | Role               |
| -------------------- | ----------------------------- | --------- | ------------------ |
| `suite366-vllm-llm`  | `nvidia/Gemma-4-31B-IT-NVFP4`  | `8001`    | Chat / vision LLM  |
| `suite366-vllm-embed`| `Qwen/Qwen3-VL-Embedding-8B`   | `8002`    | Embeddings (RAG)   |

> The model IDs above are indicative defaults — confirm the exact HuggingFace IDs
> for your hardware before a production run, and override `LLM_MODEL` /
> `EMBED_MODEL` if needed.

## Enabling it

vLLM is **auto-enabled when a GPU is detected**. To control it explicitly:

```bash
sudo WITH_GPU=1 ./install.sh    # force (fail if no usable GPU)
sudo WITH_GPU=0 ./install.sh    # never (configure an external provider in-app)
```

Requirements for the GPU path:

- An **NVIDIA GPU** with a working driver (`nvidia-smi`).
- **Docker** + the **NVIDIA Container Toolkit** (the installer installs the
  toolkit if the `nvidia` runtime is missing).
- A **vLLM image that matches your GPU**. The default `VLLM_IMAGE` is the NVIDIA
  NGC build for the **DGX Spark** (arm64 / Blackwell GB10 / sm_121). On a discrete
  x86 GPU, set e.g. `VLLM_IMAGE=vllm/vllm-openai:latest` (or a pinned tag).
- A **Hugging Face token** (`HF_TOKEN`) for gated models. Models download on first
  boot, then cache under `/opt/suite366/models`.

## Memory tuning (unified-memory appliances)

On a GB10 / DGX Spark a single ~128 GB pool is shared between CPU, GPU, OS,
runtime, model weights and KV cache. Both vLLM instances draw on it, so each is
bounded:

| Variable             | Default  | Role                                              |
| -------------------- | -------- | ------------------------------------------------- |
| `LLM_GPU_MEM_UTIL`   | `0.55`   | Pool share for the generative model               |
| `EMBED_GPU_MEM_UTIL` | `0.20`   | Pool share for embeddings                         |
| `LLM_MAX_NUM_SEQS`   | `4`      | Max concurrent generative streams (small batch)   |
| `LLM_MAX_MODEL_LEN`  | `131072` | Max context length (generative)                   |

Keep `LLM_GPU_MEM_UTIL + EMBED_GPU_MEM_UTIL < 1.0` with margin for the OS and KV
growth. On a discrete GPU with dedicated VRAM you can raise these values.

> **NVFP4 is auto-detected.** `*-NVFP4` checkpoints carry their quantization in
> their config, so the installer does **not** force `--quantization` (vLLM picks
> the right FP4 backend). Set it only to quantize a non-pre-quantized checkpoint
> at load time.

## Wiring the app to vLLM (manual, post-install)

vLLM runs **outside** the cluster and exposes **two distinct** endpoints. The app
routes all *system-provider* traffic through a single `LITELLM_BASE_URL`, which is
not enough to split chat from embeddings — so wire it by hand.

> ⚠️ Use the **host IP** (printed at the end of the install), **not**
> `suite366.local`: k3s pods do not resolve the `.local` mDNS name (host-side
> resolution only).

**Recommended — 2 `CUSTOM` providers in the Suite 366 admin** (org providers use
their own `baseUrl`/`apiKey` and never go through `LITELLM_BASE_URL`):

| Provider (CUSTOM, OpenAI-compatible) | Base URL                  | Model                          | Key                  |
| ------------------------------------ | ------------------------- | ------------------------------ | -------------------- |
| Chat / vision                        | `http://<HOST_IP>:8001/v1` | `nvidia/Gemma-4-31B-IT-NVFP4`  | vLLM key (printed)   |
| Embeddings                           | `http://<HOST_IP>:8002/v1` | `Qwen/Qwen3-VL-Embedding-8B`   | vLLM key (printed)   |

The vLLM API key is generated at install time and shown in the final summary.

## Operating the vLLM stack

```bash
systemctl status suite366-vllm        # the vLLM stack (systemd oneshot)
docker logs -f suite366-vllm-llm      # generative model logs
docker logs -f suite366-vllm-embed    # embeddings model logs
```

Config lives in `/opt/suite366/llm/` (`docker-compose.yml` + generated `.env`).
The installer warms the JIT once after boot so the first real user request isn't
penalized by cold codegen.

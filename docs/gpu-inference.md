# On-host GPU inference (vLLM)

Suite 366 can run its LLM **entirely on your own GPU** — no external API, nothing
leaves the machine. This overlay replicates the Devana **DGX Spark (NVIDIA GB10)**
configuration: **Gemma 4 26B-A4B** in NVFP4, served through vLLM's
OpenAI-compatible API, plus a **Qwen3-VL 8B** embedding model for semantic search.

## Requirements

- An **NVIDIA GPU with NVFP4 support** (Blackwell / GB10 — e.g. DGX Spark).
  The model is NVFP4-quantized; it will not run on older GPUs or CPU.
- **NVIDIA Container Toolkit** installed, so Docker can access the GPU
  (`docker run --rm --gpus all nvidia/cuda:13.0.1-base nvidia-smi` should work).
- A **Hugging Face token** with access to the models (first boot downloads them;
  they are then cached in the `hfcache` volume).
- Plenty of VRAM and disk — these are large models.

## What it adds

| Service           | Model                         | Port (internal) | Role               |
| ----------------- | ----------------------------- | --------------- | ------------------ |
| `vllm-gemma`      | `nvidia/Gemma-4-26B-A4B-NVFP4` | `8000`          | Chat / vision LLM  |
| `vllm-embeddings` | `Qwen/Qwen3-VL-Embedding-8B`   | `8000`          | Embeddings (RAG)   |

The overlay also points the `app` at `vllm-gemma` via `LLM_API_URL`,
`LLM_API_KEY`, `LLM_MODEL`.

## Start

```bash
# 1. Put your HF token in .env
echo "HF_TOKEN=hf_xxx" >> .env

# 2. Launch the base stack + the GPU overlay together
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

# 3. The model download + warmup takes several minutes on first boot
docker compose -f docker-compose.yml -f docker-compose.gpu.yml logs -f vllm-gemma
```

vLLM is ready when the logs show it listening on `:8000`. Quick check from the
host (if you publish the port) or from another container:

```bash
docker compose exec app node -e "fetch('http://vllm-gemma:8000/v1/models').then(r=>r.text()).then(console.log)"
```

## Wiring details

The app talks to vLLM over the internal Docker network:

- **Chat / vision** → `LLM_API_URL=http://vllm-gemma:8000/v1`, `LLM_MODEL=gemma-4-26b-a4b-nvfp4`
  (set automatically by the overlay).
- **Embeddings** → configure the embedding provider inside Suite 366 with the
  endpoint `http://vllm-embeddings:8000/v1` and model `qwen3-vl-embedding-8b`.

`LLM_API_KEY` can be any non-empty string — vLLM does not validate it unless you
start the server with `--api-key`.

## Offline boots

The Spark runs fully offline once the models are cached. After the first
successful download, set in `.env`:

```env
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
```

and restart. vLLM will then load only from the `hfcache` volume, with no calls
to Hugging Face.

## Notes

- `boot-guard.sh` waits for `nvidia-smi` to respond before launching vLLM — on a
  cold reboot the GB10 driver isn't always ready when Docker restarts the
  container, which would otherwise crash the engine init.
- `tool_chat_template_gemma4.jinja` is the chat template enabling Gemma 4 tool
  calling and the reasoning parser. It is mounted into the container as-is.
- Flags (`--quantization modelopt`, `--kv-cache-dtype fp8`, `--moe-backend marlin`,
  `--max-model-len 262144`, …) mirror the production Spark exactly. Adjust
  `--gpu-memory-utilization` and `--max-model-len` if you have less VRAM.

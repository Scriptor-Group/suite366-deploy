# Qwen3.8-Flash-Next on one Spark — the vLLM patch set

`nvidia/Qwen3.8-Flash-Next-NVFP4` weighs 123.5 GiB on disk; the GB10 has 121.6 GiB
of unified memory. It only fits because 47.7 GiB of it is an n-gram embedding
table of which a token reads 16 rows: this directory serves that table from the
NVMe through `mmap` instead of loading it, leaving ~77 GiB of weights resident.

Everything here is vendored, unmodified, from
[blazux/qwen3.8-Flash-DGX](https://github.com/blazux/qwen3.8-Flash-DGX) at the
commit recorded in `UPSTREAM_COMMIT` (Apache-2.0, `LICENSE.upstream`). The
`Dockerfile` is their `Dockerfile.v0.29`: overlays on the official
`vllm/vllm-openai:v0.29.0` image, no vLLM rebuild. What each step does:

| # | file | effect |
|---|---|---|
| 1 | `src/vllm_ple_mmap.py` | the n-gram (PLE) table is `mmap`-ed from the checkpoint's own shards (`VLLM_PLE_MMAP=1`); needs a local snapshot path, hence `serve-flash-next.sh` |
| 2 | (sed in Dockerfile) | two flash-linear-attention fixes for sm_121: the 99 KiB shared-memory gate, a `num_warps` pin for a `tl.dot` race |
| 4 | `src/patch_mamba_block_size.py` | prefix caching: the engine core overwrote `block_size` with the smallest KV group's |
| 5 | `src/patch_qsa_exact_topk.py` | exact `torch.topk` fallback for Qwen Sparse Attention (`VLLM_QSA_EXACT_TOPK=1`, off by default) |
| 6 | `src/vllm_fp8_hybrid_modelopt.py` | "hybrid" mode (`VLLM_FP8_HYBRID=1`): fp8 side layers next to NVFP4 experts. Kept so the image is byte-identical to upstream; the appliance serves the checkpoint as published |
| 8 | (ADD in Dockerfile) | deterministic `persistent_topk` kernel from jschmied's repo, pinned by commit and sha256, compiled with the image's nvcc for sm_121a (`VLLM_QSA_DET_TOPK=1`) |
| 10 | `src/patch_mtp_draft_vocab.py`, `src/draft_vocab_65536.npy` | the MTP drafter scores 65,536 token ids instead of 248,320; the target verifies the full vocabulary, outputs stay exact |
| 11 | `src/patch_block_fp8_mtp.py` | vllm#55513 backport: NVIDIA keeps the MTP experts in blockwise FP8, v0.29.0 dies on `w2_weight_scale_inv` without it |
| 12 | `src/patches/qwen-tool-preamble.patch` | the `qwen3` tool parser dropped text after a quoted or malformed `<tool_call>` |

`lib/vllm.sh` fetches this directory and builds the image on the appliance
(`docker build`, ~3 min, needs the base image and network for the pinned ADDs).
The tag carries the base image version and the upstream commit, so refreshing
the patch set means updating `UPSTREAM_COMMIT` and `FLASH_NEXT_PATCHES_COMMIT`
in `lib/config.sh`.

Refreshing from upstream:

```bash
git clone --depth 1 https://github.com/blazux/qwen3.8-Flash-DGX /tmp/fd
cp /tmp/fd/Dockerfile.v0.29 Dockerfile && cp /tmp/fd/LICENSE LICENSE.upstream
cp /tmp/fd/src/{vllm_ple_mmap,patch_mamba_block_size,patch_qsa_exact_topk,vllm_fp8_hybrid_modelopt,patch_mtp_draft_vocab,patch_block_fp8_mtp}.py src/
cp /tmp/fd/src/draft_vocab_65536.npy src/ && cp /tmp/fd/src/patches/qwen-tool-preamble.patch src/patches/
git -C /tmp/fd rev-parse HEAD > UPSTREAM_COMMIT
```

Then re-read the Dockerfile diff before committing: it is third-party code that
runs as root inside the vLLM container.

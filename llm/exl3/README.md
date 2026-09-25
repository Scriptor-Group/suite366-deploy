# OrcaSAQ-2-27B on the Spark — the EXL3 serving image

`orcarouter/OrcaSAQ-2-27B` is Qwen3.8-27B quantised with a sensitivity-searched
mixed-precision trellis code (the EXL3 / QTIP family): 3.21 bits per decoder
weight, a 6-bit `lm_head`, an int8 embedding table and a 4-bit MTP head, 12.3 GB
on disk against 54 GB of BF16. vLLM cannot read that format by itself; this
directory is what the `orcasaq` profile builds on the box, over the official
`vllm/vllm-openai` image, as `suite366/vllm-exl3:<base>-r<LLM_EXL3_IMAGE_REV>`.

| file | role |
|---|---|
| `Dockerfile` | the two layers below, every input pinned by content |
| `arm64-build.sh` | makes the exllamav3 source tree build on the Grace CPU (see below) |
| `aarch64_stubs.cpp` | the symbols of the dropped x86 sources, so the extension links |
| `UPSTREAM_COMMIT` | the OrcaSAQ2-kernel commit the plugin files are fetched from |

**Layer 1 — exllamav3 v1.5.1** ([turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3),
MIT), the library whose CUDA extension holds the trellis kernels (`exl3_gemm`,
`reconstruct`, `had_r_128`, `hgemm_recon`). Upstream publishes x86_64 wheels only
and the extension is ABI-linked to torch and the CUDA major, so it is compiled
in the image, for sm_121, against the image's own torch and nvcc. Its CPU side
assumes x86: five translation units are AVX2/AVX-512 intrinsics through and
through (the CPU MoE experts of its offload mode, the CPU all-reduce of its
tensor-parallel runtime, the ISA probes) and two spin waits call the x86 `pause`
builtin. None of that is reachable when one dense checkpoint is served on one
GPU, so `arm64-build.sh` drops the five files, rewrites the two pauses to
`yield`, and adds `aarch64_stubs.cpp`: every probe answers "absent", every entry
point refuses instead of computing. The CUDA kernels are plain PTX and compile
unchanged.

**Layer 2 — the orcasaq2 vLLM plugin** ([Continuum-AI-Corp/OrcaSAQ2-kernel](https://github.com/Continuum-AI-Corp/OrcaSAQ2-kernel),
Apache-2.0 per its `pyproject.toml`), fetched file by file at the commit in
`UPSTREAM_COMMIT` with a sha256 on each. It registers `quant_method: "exl3"`
through vLLM's own `register_quantization_config`, keeps each shard of a fused
layer (`qkv_proj`, `gate_up_proj`) as its own trellis because the shards carry
different bit widths, wraps the `embed_tokens` and `lm_head` constructors that
vLLM's Qwen3.5 model file builds without a quant config, and exposes the shard
GEMM as a torch custom op so `torch.compile` and CUDA graphs stay on. Decode
rows go through the fused trellis kernel; a prefill above 144 rows reconstructs
the dense weight into a scratch buffer and runs a cuBLAS GEMM, as exllamav3's
own engine does. Tensor parallelism is not implemented (the appliance runs
`-tp 1`). vLLM discovers it through the `vllm.general_plugins` entry point; it
only acts on a checkpoint whose config says `exl3`.

Refreshing either input:

```bash
# exllamav3: new tag -> EXL3_VERSION + EXL3_SHA256 in the Dockerfile
curl -sL https://github.com/turboderp-org/exllamav3/archive/refs/tags/v<X>.tar.gz | sha256sum
# the plugin: new commit -> UPSTREAM_COMMIT, ORCASAQ2_COMMIT and the eight file checksums
git clone -q https://github.com/Continuum-AI-Corp/OrcaSAQ2-kernel /tmp/ok && git -C /tmp/ok rev-parse HEAD
(cd /tmp/ok && sha256sum pyproject.toml README.md orcasaq2/*.py orcasaq2/patches/*.py)
```

Then bump `LLM_EXL3_IMAGE_REV` in `llm/profiles.sh` (that is what makes a box
rebuild), re-run `arm64-build.sh`'s expectations in your head — it fails loudly
when upstream moves one of the five files or the pause builtin — and re-read
the diff: this is third-party code that runs as root inside the vLLM container.

# The unified vLLM image

One image for everything the appliance serves except Flash-Next: the
`qwen27b`, `orcasaq` and `gemma` profiles, the transcription engine and the
embeddings. `Dockerfile` lays three things over the official `vllm/vllm-openai`
release (v0.30.0 by default):

| layer | what | for |
|---|---|---|
| 1 | exllamav3 v1.5.1 compiled for sm_121 + the orcasaq2 vLLM plugin | OrcaSAQ-2-27B, a 3.2-bit EXL3 trellis checkpoint vLLM cannot read by itself |
| 2 | `soundfile`, `librosa`, PyAV | `/v1/audio/transcriptions`: the arm64 image decodes **no** audio without them |
| 3 | `tool_chat_template_gemma4.jinja` at `/app/` | `--tool-call-parser gemma4` crashes at boot without it |

Until 2026-10 each of those was a separate image built on the box (`llm/exl3/`,
`llm/stt/`), Gemma was pinned to an April nightly (vLLM 0.19) and the embed ran
the plain upstream image: four images, two of them compiled on every box. Now
there is one, and CI publishes it.

**Measured on the test Spark (2026-10-05/06, base v0.30.0)**, side by side with
the previous images: OrcaSAQ greedy outputs 5/5 identical, a 72 s transcription
identical word for word, image embeddings at 0.9989 cosine, same decode speed
on all three generative models (21 / 30 / 30 t/s), prefill 20-35 % faster
(1 900 tok/s on the 27B against ~1 400), Gemma's prefix cache back
(`--disable-hybrid-kv-cache-manager`, see `llm/serve-llm.sh`), tools, thinking,
JSON, vision and streaming passing everywhere. The orcasaq2 plugin is loaded by
every vLLM process and acts only on an EXL3 checkpoint: inert under the others.

## Where the image comes from

- **CI** — `.github/workflows/publish-vllm-image.yml` builds this Dockerfile on
  a hosted arm64 runner on every push to `main` that touches it, and pushes
  `ghcr.io/scriptor-group/suite-366-vllm:<base tag>-u<rev>` (`rev` =
  `LLM_UNIFIED_IMAGE_REV` in `llm/profiles.sh`). A tag that exists is never
  overwritten: bump the revision to publish a change. Rolling the fleet onto it
  is the Release workflow (`vllm_image=`), once the image is there.
- **The box** — `lib/vllm.sh` (install) and `switch-model.sh` (a switch, or
  `converge` after `update.sh`) look at the label `suite366.unified` on
  `VLLM_IMAGE`. Present: that is the engine image. Absent (an offline package
  that shipped the plain upstream image, an older channel, an operator's
  `VLLM_IMAGE`): the same Dockerfile is built on the box over it, as
  `suite366/vllm-unified:<base tag>-u<rev>`, ~5 min on the Spark's 20 cores,
  with the generative and transcription engines stopped first
  (`build_with_engines_down`).

Build context is `llm/` (the template lives there), Dockerfile this one:

```bash
docker build -f llm/unified/Dockerfile --build-arg BASE_IMAGE=vllm/vllm-openai:v0.30.0 \
  -t suite366/vllm-unified:v0.30.0-u1 llm
```

## Flash-Next is not in it

`llm/flash-next/` stays a separate image over vLLM **v0.29.0**: the patch set
that serves its 47.7 GiB n-gram table from the NVMe is written against that
release, and on the v0.30.0 base the model's resident footprint grows by ~3 GiB
while the recipe's fast loader removes the swap the September boot was counting
as free — at the profile's 0.71 next to the embed it no longer starts (1.4 GiB
of KV where a 131k request needs 4). Alone at 0.82 it runs, and better than in
September; moving it onto the unified base is a product decision (an embed small
enough to fit beside it, or a profile that stops the embed), not a build one.

## The EXL3 layer, in detail

[turboderp-org/exllamav3](https://github.com/turboderp-org/exllamav3) (MIT) is
the library whose CUDA extension holds the trellis kernels (`exl3_gemm`,
`reconstruct`, `had_r_128`, `hgemm_recon`). Upstream publishes x86_64 wheels only
and the extension is ABI-linked to torch and the CUDA major, so it is compiled
in the image, for sm_121, against the image's own torch and nvcc (2.13.0+cu130
and 13.0 on v0.29.0, v0.30.0 and v0.31.0 alike). Its CPU side assumes x86: five
translation units are AVX2/AVX-512 intrinsics through and through (the CPU MoE
experts of its offload mode, the CPU all-reduce of its tensor-parallel runtime,
the ISA probes) and two spin waits call the x86 `pause` builtin. None of that is
reachable when one dense checkpoint is served on one GPU, so `arm64-build.sh`
drops the five files, rewrites the two pauses to `yield`, and adds
`aarch64_stubs.cpp`: every probe answers "absent", every entry point refuses
instead of computing. The CUDA kernels are plain PTX and compile unchanged.

[Continuum-AI-Corp/OrcaSAQ2-kernel](https://github.com/Continuum-AI-Corp/OrcaSAQ2-kernel)
(Apache-2.0 per its `pyproject.toml`) is the vLLM plugin, fetched file by file
at the commit in `UPSTREAM_COMMIT` with a sha256 on each. It registers
`quant_method: "exl3"` through vLLM's own `register_quantization_config`, keeps
each shard of a fused layer (`qkv_proj`, `gate_up_proj`) as its own trellis
because the shards carry different bit widths, wraps the `embed_tokens` and
`lm_head` constructors that vLLM's Qwen3.5 model file builds without a quant
config, and exposes the shard GEMM as a torch custom op so `torch.compile` and
CUDA graphs stay on. Decode rows go through the fused trellis kernel; a prefill
above 144 rows reconstructs the dense weight into a scratch buffer and runs a
cuBLAS GEMM, as exllamav3's own engine does. Tensor parallelism is not
implemented (the appliance runs `-tp 1`).

Refreshing either input:

```bash
# exllamav3: new tag -> EXL3_VERSION + EXL3_SHA256 in the Dockerfile
curl -sL https://github.com/turboderp-org/exllamav3/archive/refs/tags/v<X>.tar.gz | sha256sum
# the plugin: new commit -> UPSTREAM_COMMIT, ORCASAQ2_COMMIT and the eight file checksums
git clone -q https://github.com/Continuum-AI-Corp/OrcaSAQ2-kernel /tmp/ok && git -C /tmp/ok rev-parse HEAD
(cd /tmp/ok && sha256sum pyproject.toml README.md orcasaq2/*.py orcasaq2/patches/*.py)
```

Then bump `LLM_UNIFIED_IMAGE_REV` in `llm/profiles.sh` (that is what makes CI
publish and a box rebuild), re-run `arm64-build.sh`'s expectations in your head
— it fails loudly when upstream moves one of the five files or the pause
builtin — and re-read the diff: this is third-party code that runs as root
inside the vLLM container.

## Moving the base

`ARG BASE_IMAGE` is the only knob. v0.31.0 (2026-10-05) builds and runs the 27B
with every check passing (prefill +34 % over v0.29.0); the audio extras are
still missing from it, torch and Python are unchanged. Two things to know before
moving: FlashInfer 0.7's autotune takes ~6 min on the first boot of each new
version (cached afterwards, per model shapes), and on v0.31.0 `/health` was
seen answering 200 during that autotune while the first request was reset —
on v0.30.0 it answers only once the engine serves, measured. Re-check the
compose healthchecks against the new base before rolling it.

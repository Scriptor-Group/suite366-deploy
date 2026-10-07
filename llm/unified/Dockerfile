# llm/unified/Dockerfile — ONE vLLM image for everything the appliance serves
# except Flash-Next: the generative profiles qwen27b, orcasaq and gemma, the
# transcription engine and the embeddings. The official image plus what each
# of them used to get in a layer of its own:
#
#   1. exllamav3's CUDA kernels compiled for the GB10 and the orcasaq2 plugin
#      that registers quant_method "exl3" (what llm/exl3/ built, for OrcaSAQ);
#   2. the audio extras the arm64 image ships without (what llm/stt/ built:
#      without soundfile and PyAV, /v1/audio/transcriptions decodes NOTHING);
#   3. Gemma 4's tool chat template, baked in next to the compose's bind-mount.
#
# Build context = llm/ (the template lives there), Dockerfile = this file:
#   docker build -f llm/unified/Dockerfile --build-arg BASE_IMAGE=… -t … llm
# Published by .github/workflows/publish-vllm-image.yml on every change to this
# directory on main, as ghcr.io/scriptor-group/suite-366-vllm:<base tag>-u<rev>,
# and pulled by the boxes (channel.json vllm_image). The label below is how the
# host side recognises it: lib/vllm.sh and switch-model.sh check it and, when
# VLLM_IMAGE is a plain upstream image (an offline package, an older channel),
# build this same Dockerfile on the box instead — ~5 min on the Spark's 20
# cores, exllamav3 being 160 s of it. Bump LLM_UNIFIED_IMAGE_REV in
# llm/profiles.sh whenever this file or its companions change: the revision is
# in the tag, and the tag is what makes a box rebuild (or the workflow publish).
#
# Measured on the test Spark (2026-10-05/06, base v0.30.0): every model gives
# the same answers as on its previous image (OrcaSAQ greedy 5/5 identical, a
# 72 s transcription word for word, image embeddings at 0.9989 cosine), the
# same decode speed, and a 20-35 % faster prefill. Flash-Next stays on
# llm/flash-next/ (a vLLM patch set on v0.29.0): on this base its resident
# footprint no longer leaves room for the embed beside it.
ARG BASE_IMAGE=vllm/vllm-openai:v0.30.0
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG UNIFIED_REV=1
LABEL suite366.unified="${UNIFIED_REV}" \
      suite366.base="${BASE_IMAGE}" \
      org.opencontainers.image.source="https://github.com/Scriptor-Group/suite366-deploy" \
      org.opencontainers.image.description="Suite 366 appliance vLLM: the official image + exllamav3/EXL3, audio extras, Gemma 4 chat template"

# --- 1a. exllamav3 v1.5.1 (MIT), compiled for the GB10 -----------------------
# Upstream publishes x86_64 wheels only and the extension is ABI-linked to torch
# and the CUDA major, so it is compiled HERE, for sm_121, against the image's
# own torch (2.13.0+cu130 on v0.29.0, v0.30.0 and v0.31.0 alike) and nvcc
# (13.0). arm64-build.sh + aarch64_stubs.cpp drop its x86-only CPU paths first
# (the reasons are in those files). CPATH: torch's cusparse header lives in the
# pip `nvidia` tree, not under /usr/local/cuda, and cpp_extension does not add
# that directory itself. MAX_JOBS: 12 on the Spark; a hosted arm64 runner has 4
# cores and the workflow passes what it has.
ARG EXL3_VERSION=1.5.1
ARG EXL3_SHA256=97d61c9f32b5363a90b465d6387c16d89f9e43f6f068032a4e61434d493c2a29
ARG CUDA_ARCH=12.1
ARG MAX_JOBS=12
ADD --checksum=sha256:${EXL3_SHA256} \
    https://github.com/turboderp-org/exllamav3/archive/refs/tags/v${EXL3_VERSION}.tar.gz /tmp/exllamav3.tar.gz
COPY unified/arm64-build.sh unified/aarch64_stubs.cpp /tmp/exl3-arm64/
RUN cd /tmp && tar xzf exllamav3.tar.gz \
 && bash /tmp/exl3-arm64/arm64-build.sh "/tmp/exllamav3-${EXL3_VERSION}" \
 && cd "/tmp/exllamav3-${EXL3_VERSION}" \
 && CPATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include \
    TORCH_CUDA_ARCH_LIST="${CUDA_ARCH}" MAX_JOBS="${MAX_JOBS}" \
    python3 -m pip install --no-cache-dir --no-build-isolation --no-deps . \
 && python3 -m pip install --no-cache-dir marisa_trie==1.4.1 \
 && cd / && rm -rf /tmp/exllamav3.tar.gz "/tmp/exllamav3-${EXL3_VERSION}" /tmp/exl3-arm64 \
 && python3 -c "import importlib.metadata as m, importlib.util as u; assert u.find_spec('exllamav3_ext'), 'no compiled extension'; print('exllamav3', m.version('exllamav3'), 'built for sm_' + '${CUDA_ARCH}'.replace('.', ''))"

# --- 1b. the orcasaq2 vLLM plugin (Apache-2.0), pinned file by file ----------
# Registers quant_method "exl3" through vLLM's own register_quantization_config,
# wraps the embedding and lm_head constructors the Qwen3.5 model file builds
# without a quant config, and exposes the shard GEMM as a torch custom op so
# torch.compile and CUDA graphs stay on. Its entry point (vllm.general_plugins)
# is loaded by every vLLM process at start and only acts on an exl3 checkpoint:
# measured inert under the other models (it logs "armed" and does nothing).
ARG ORCASAQ2_COMMIT=7ddffb12c00c24b8bc6b1164723c04ac490a91bc
ARG ORCASAQ2=https://raw.githubusercontent.com/Continuum-AI-Corp/OrcaSAQ2-kernel/${ORCASAQ2_COMMIT}
ADD --checksum=sha256:75fa1d325bd322dfd9c265f4fa29520008ec4e3fe164916783829bde897ce40a ${ORCASAQ2}/pyproject.toml /opt/orcasaq2/pyproject.toml
ADD --checksum=sha256:3bb33a794e859b7f78a4ba4c82770b6b8acde85428b232f05c607b6805f5caa9 ${ORCASAQ2}/README.md /opt/orcasaq2/README.md
ADD --checksum=sha256:a98e026859857223438743b33a97e4358c7d34f644c4c3d576d7b27cfc2d0fbb ${ORCASAQ2}/orcasaq2/__init__.py /opt/orcasaq2/orcasaq2/__init__.py
ADD --checksum=sha256:e6b45b4633153e9f969cf9489e66139db0857f96951dec2ffd08231cd8340d78 ${ORCASAQ2}/orcasaq2/config.py /opt/orcasaq2/orcasaq2/config.py
ADD --checksum=sha256:bf4654d6b33df18a48c05e595ae413e5ad564ef061dd2fde29605b1f24cdc1ef ${ORCASAQ2}/orcasaq2/heads.py /opt/orcasaq2/orcasaq2/heads.py
ADD --checksum=sha256:15cb757a205faad72c44481a36834557886294532148091b50b5255bb9af6e7e ${ORCASAQ2}/orcasaq2/ops.py /opt/orcasaq2/orcasaq2/ops.py
ADD --checksum=sha256:8826b721772ce3e62b5c8f724e1e62d1f71f46532d649ad7e942a5a16aaac6cb ${ORCASAQ2}/orcasaq2/patches/__init__.py /opt/orcasaq2/orcasaq2/patches/__init__.py
ADD --checksum=sha256:c7351fc2758936ab1b97392f0c811772f80032f438d6131b8bc84c0865551928 ${ORCASAQ2}/orcasaq2/patches/int8_embedding.py /opt/orcasaq2/orcasaq2/patches/int8_embedding.py
RUN python3 -m pip install --no-cache-dir --no-deps /opt/orcasaq2 && rm -rf /opt/orcasaq2 \
 && python3 -c "import importlib.metadata as m; assert any(e.name == 'orcasaq2' for e in m.entry_points(group='vllm.general_plugins')); print('orcasaq2 plugin registered')"

# --- 2. the audio extras for /v1/audio/transcriptions -------------------------
# vllm/vllm-openai (arm64) has neither soundfile nor PyAV, and AudioMediaIO
# .load_bytes — what the transcription route decodes the upload with — fails
# on EVERY format with "Please install vllm[audio] for audio support"; verified
# on v0.29.0 (2026-09-22) and still true of v0.30.0 and v0.31.0 (2026-10-05).
# Pinned to the versions that resolved that day; ~100 MB. Not
# `pip install "vllm[audio]"`: on arm64 that would re-resolve vllm itself
# from PyPI. The three packages ARE that extra.
RUN python3 -m pip install --break-system-packages --no-cache-dir \
      soundfile==0.14.0 librosa==1.0.0 av==18.1.0 \
 && python3 -c "import soundfile, av, librosa; print('audio extras', soundfile.__version__, av.__version__, librosa.__version__)"

# --- 3. Gemma 4's tool chat template -----------------------------------------
# --tool-call-parser gemma4 crashes at boot without it. The compose still
# bind-mounts the same file over this path (a box's host layer may be newer
# than its image); baking it in means the image also serves on its own.
COPY tool_chat_template_gemma4.jinja /app/tool_chat_template_gemma4.jinja

RUN python3 -c "import importlib.metadata as m; print('suite366 unified image on vllm', m.version('vllm'))"

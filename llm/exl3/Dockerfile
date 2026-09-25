# llm/exl3/Dockerfile — the vLLM image that serves EXL3 (exllamav3 trellis)
# checkpoints on the appliance: orcarouter/OrcaSAQ-2-27B, a 3.2-bit
# mixed-precision quantisation of Qwen3.8-27B (12 GB on disk against 21.9 for
# the NVFP4 build). Built on the box by lib/vllm.sh / switch-model.sh as
# suite366/vllm-exl3:<base>-r<LLM_EXL3_IMAGE_REV> (llm/profiles.sh). Bump
# LLM_EXL3_IMAGE_REV whenever this file or its two companions change: the tag
# is how a box knows to rebuild.
#
# Two layers over the official image, both pinned by content:
#   1. exllamav3, whose CUDA extension holds the trellis kernels. Upstream
#      publishes x86_64 wheels only and the extension is ABI-linked to torch and
#      the CUDA major, so it is compiled HERE, for sm_121, against the image's
#      own torch (2.13.0+cu130) and nvcc (13.0). arm64-build.sh + aarch64_stubs.cpp
#      drop its x86-only CPU paths first (the reasons are in those files).
#      ~N min on the Spark's 20 cores (measured value in llm/profiles.sh).
#   2. the orcasaq2 vLLM plugin (Continuum-AI-Corp/OrcaSAQ2-kernel, pinned to
#      one commit, every file by sha256): registers quant_method "exl3" through
#      vLLM's own register_quantization_config, wraps the embedding and lm_head
#      constructors the Qwen3.5 model file builds without a quant config, and
#      exposes the shard GEMM as a torch custom op so torch.compile and CUDA
#      graphs stay on. Its entry point (vllm.general_plugins) is loaded by
#      every vLLM process at start; it only acts on an exl3 checkpoint.
#
# The rest of the image is untouched: the embed and the transcription engine
# keep running the plain base image.
ARG BASE_IMAGE=vllm/vllm-openai:v0.29.0
FROM ${BASE_IMAGE}

# --- 1. exllamav3 v1.5.1 (MIT), compiled for the GB10 ------------------------
ARG EXL3_VERSION=1.5.1
ARG EXL3_SHA256=97d61c9f32b5363a90b465d6387c16d89f9e43f6f068032a4e61434d493c2a29
ARG CUDA_ARCH=12.1
ARG MAX_JOBS=12
ADD --checksum=sha256:${EXL3_SHA256} \
    https://github.com/turboderp-org/exllamav3/archive/refs/tags/v${EXL3_VERSION}.tar.gz /tmp/exllamav3.tar.gz
COPY arm64-build.sh aarch64_stubs.cpp /tmp/exl3-arm64/
# CPATH: torch's cusparse header lives in the pip `nvidia` tree, not under
# /usr/local/cuda, and cpp_extension does not add that directory itself.
RUN cd /tmp && tar xzf exllamav3.tar.gz \
 && bash /tmp/exl3-arm64/arm64-build.sh "/tmp/exllamav3-${EXL3_VERSION}" \
 && cd "/tmp/exllamav3-${EXL3_VERSION}" \
 && CPATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/include \
    TORCH_CUDA_ARCH_LIST="${CUDA_ARCH}" MAX_JOBS="${MAX_JOBS}" \
    python3 -m pip install --no-cache-dir --no-build-isolation --no-deps . \
 && python3 -m pip install --no-cache-dir marisa_trie==1.4.1 \
 && cd / && rm -rf /tmp/exllamav3.tar.gz "/tmp/exllamav3-${EXL3_VERSION}" /tmp/exl3-arm64 \
 && python3 -c "import importlib.metadata as m, importlib.util as u; assert u.find_spec('exllamav3_ext'), 'no compiled extension'; print('exllamav3', m.version('exllamav3'), 'built for sm_' + '${CUDA_ARCH}'.replace('.', ''))"

# --- 2. the orcasaq2 vLLM plugin (Apache-2.0), pinned file by file ------------
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

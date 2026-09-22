# The transcription vLLM: the official image plus the audio extras it ships
# without. Built ON THE BOX by lib/vllm.sh at install and by switch-model.sh on
# a switch, tagged suite366/vllm-stt:<base tag>-r<LLM_STT_IMAGE_REV> — bump
# LLM_STT_IMAGE_REV in llm/profiles.sh whenever this file changes, that tag is
# how a box knows to rebuild.
#
# Why a build at all: vllm/vllm-openai:v0.29.0 (arm64) has neither soundfile
# nor PyAV, and AudioMediaIO.load_bytes — what /v1/audio/transcriptions decodes
# the upload with — fails on EVERY format with "Please install vllm[audio] for
# audio support". Verified 2026-09-22 with WAV 16 kHz mono (what the meeting
# notes and voice reports send), WAV 48 kHz stereo, webm/opus (what the
# dictation upload sends) and ogg: all four failed before this layer, all four
# decode after it. Pinned to the versions that resolved that day; ~100 MB, 6 s.
#
# Not `pip install "vllm[audio]"`: on arm64 that would try to re-resolve vllm
# itself from PyPI. The three packages ARE that extra (mistral_common[audio] is
# already in the image).
#
# What the route then does with a long upload (vllm/entrypoints/speech_to_text):
# audio over the model's 30 s window is split at the quietest point of each
# window with 1 s of overlap, and the pieces are transcribed as one batch — so
# a 5 min dictation is ten requests, not one, and max_num_seqs is the knob.
ARG BASE_IMAGE=vllm/vllm-openai:v0.29.0
FROM ${BASE_IMAGE}
RUN python3 -m pip install --break-system-packages --no-cache-dir \
      soundfile==0.14.0 librosa==1.0.0 av==18.1.0

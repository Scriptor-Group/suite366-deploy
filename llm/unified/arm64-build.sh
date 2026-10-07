#!/usr/bin/env bash
# Make an exllamav3 source tree build on aarch64 (the DGX Spark's Grace CPU).
# Run by llm/exl3/Dockerfile on the unpacked release tarball, before pip.
#
# Upstream publishes x86_64 wheels only and its CPU-side code assumes x86:
#   1. five translation units are AVX2 / AVX-512 intrinsics through and through
#      (CPU MoE experts, CPU all-reduce for tensor parallel, ISA probes) —
#      they do not compile on arm64 and nothing the appliance runs reaches them;
#   2. two host-side spin waits call the x86 `pause` builtin.
# The CUDA side is plain PTX and compiles for sm_121 unchanged. The dropped
# symbols are defined by aarch64_stubs.cpp so the extension links; each probe
# reports the ISA absent and each entry point refuses rather than computing.
set -euo pipefail
SRC="${1:?usage: arm64-build.sh <exllamav3 source dir>}"
E="$SRC/exllamav3/exllamav3_ext"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$E/bindings.cpp" ]] || { echo "not an exllamav3 tree: $E" >&2; exit 1; }
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "arm64-build.sh: $(uname -m) — nothing to patch"; exit 0 ;;
esac
# 1. the x86-only translation units
for f in avx2_target.cpp avx512_target.cpp cpu/moe_mul1.cpp \
         parallel/all_reduce_cpu_avx2.cpp parallel/all_reduce_cpu_avx512.cpp; do
  [[ -f "$E/$f" ]] || { echo "expected x86 source missing (upstream moved it?): $f" >&2; exit 1; }
  rm -f "$E/$f"
done
# 2. the two host-side pauses
for f in parallel/all_reduce_cpu.cu cpu/moe_handoff.cu; do
  grep -q '__builtin_ia32_pause();' "$E/$f" \
    || { echo "expected x86 pause builtin missing (upstream changed it?): $f" >&2; exit 1; }
  sed -i 's/__builtin_ia32_pause();/__asm__ __volatile__("yield");/' "$E/$f"
done
# 3. their symbols
cp "$HERE/aarch64_stubs.cpp" "$E/aarch64_stubs.cpp"
echo "arm64-build.sh: 5 x86 sources dropped, 2 pauses rewritten, stubs added."

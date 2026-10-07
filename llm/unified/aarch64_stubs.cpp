// aarch64 build of exllamav3 (DGX Spark, GB10) — see arm64-build.sh next to this file.
//
// exllamav3 ships two CPU-side code paths written with x86 intrinsics: the CPU
// expert GEMMs of its MoE offload (cpu/moe_mul1.cpp, AVX2 / AVX-512) and the
// CPU all-reduce of its tensor-parallel runtime (parallel/all_reduce_cpu_avx*.cpp),
// plus the three "is this ISA present" probes. None of it is reachable when a
// dense EXL3 checkpoint is served on one GPU, which is the only thing the
// appliance asks of it: vLLM calls exl3_gemm / reconstruct / had_r_128 /
// hgemm_recon and nothing else. The five x86 translation units are dropped from
// the build and their symbols are defined here so the extension still links;
// every probe answers "absent" and every entry point refuses instead of
// computing.
#include <torch/extension.h>
#include "avx2_target.h"
#include "avx512_target.h"
#include "cpu/moe_mul1.h"
#include "parallel/all_reduce_cpu_avx2.h"
#include "parallel/all_reduce_cpu_avx512.h"

static void no_cpu_path()
{
    TORCH_CHECK(false, "exllamav3: this CPU path is x86-only (AVX2/AVX-512) and is not built on aarch64");
}

// ISA probes (avx2_target.cpp, avx512_target.cpp)
bool is_avx2_supported() { return false; }
bool is_f16c_supported() { return false; }
bool is_avx512_supported() { return false; }

// CPU all-reduce for tensor parallel (parallel/all_reduce_cpu_avx2.cpp, _avx512.cpp)
void enable_fast_fp() {}
void enable_fast_fp_avx2() {}
void enable_fast_fp_avx512() {}
void perform_cpu_reduce(PGContext*, size_t, uint32_t, uint32_t, uint8_t*, size_t) { no_cpu_path(); }
void perform_cpu_reduce_avx2(PGContext*, size_t, uint32_t, uint32_t, uint8_t*, size_t) { no_cpu_path(); }
void perform_cpu_reduce_avx512(PGContext*, size_t, uint32_t, uint32_t, uint8_t*, size_t) { no_cpu_path(); }
void bf16_add_inplace_avx512(uint16_t*, const uint16_t*, size_t) { no_cpu_path(); }
void bf16_add_twosrc_avx512(uint16_t*, const uint16_t*, const uint16_t*, size_t) { no_cpu_path(); }
void fp16_add_inplace_avx512(uint16_t*, const uint16_t*, size_t) { no_cpu_path(); }
void fp16_add_twosrc_avx512(uint16_t*, const uint16_t*, const uint16_t*, size_t) { no_cpu_path(); }
void cpu_reduce_parallel(void (*)(uint16_t*, const uint16_t*, const uint16_t*, size_t),
                         void (*)(uint16_t*, const uint16_t*, size_t),
                         uint16_t*, const uint16_t*, const uint16_t*, size_t, int) { no_cpu_path(); }

// CPU MoE experts (cpu/moe_mul1.cpp)
int64_t exl3_moe_cpu_make_layer(
    const std::vector<at::Tensor>&, const std::vector<at::Tensor>&, const std::vector<at::Tensor>&,
    const std::vector<at::Tensor>&, const std::vector<at::Tensor>&, const std::vector<at::Tensor>&,
    const std::vector<at::Tensor>&, const std::vector<at::Tensor>&, const std::vector<at::Tensor>&,
    const std::vector<at::Tensor>&, const std::vector<at::Tensor>&, const std::vector<at::Tensor>&,
    int64_t, double, int64_t) { no_cpu_path(); return 0; }
void exl3_moe_cpu_free_layer(int64_t) {}
void exl3_moe_cpu_forward(int64_t, const at::Tensor&, const at::Tensor&, const at::Tensor&, at::Tensor&, int64_t) { no_cpu_path(); }
void exl3_moe_cpu_forward_raw(int64_t, const at::Half*, const int32_t*, const at::Half*, float*, int, int, int) { no_cpu_path(); }
void exl3_moe_cpu_stage_experts(int64_t, const uint32_t*, int, uint8_t*, int) { no_cpu_path(); }
void exl3_moe_cpu_set_prof(bool) {}
int64_t exl3_moe_cpu_pool_stress(int, int, int, int) { no_cpu_path(); return 0; }
bool exl3_moe_cpu_has_avx2() { return false; }
bool exl3_moe_cpu_has_avx512_bw() { return false; }
bool exl3_moe_cpu_has_avx512_vnni() { return false; }
bool exl3_moe_cpu_has_avx512_vbmi() { return false; }

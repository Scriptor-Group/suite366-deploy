#!/usr/bin/env python3
"""Build-time patch (qwen38-flash-dgx, v0.29 base): backport of vllm#55513, "Fix block FP8 MTP in
ModelOpt mixed checkpoints".

NVIDIA's own quant (nvidia/Qwen3.8-Flash-Next-NVFP4 and checkpoints derived from it) is a ModelOpt
MIXED_PRECISION checkpoint whose MTP draft head keeps its routed experts in blockwise FP8 (fp8
``weight`` + ``weight_scale_inv``, 128x128 blocks), declared as
``quantized_layers["mtp.layers.0.mlp.experts"]`` with quant_algo FP8_PB_WO (config.json) or
FP8_BLOCK_SCALES (hf_quant_config.json). vLLM v0.29.0 cannot load that drafter:

  * ``_make_draft_vllm_config`` (qwen4_exp/nvidia/mtp.py) shifts ``ignored_layers`` and
    ``exclude_modules`` from checkpoint layer 0 to the draft's runtime index (``mtp.layers.48``),
    but not ``quantized_layers``, so the draft's experts are never found in the map;
  * ``ModelOptMixedPrecisionConfig.get_quant_method`` has no RoutedExperts method for either
    block-FP8 algo name.

Either gap alone leaves the experts unquantized, and the load dies with
``AttributeError: Layer mtp.layers.48.mlp.experts has no parameter 'w2_weight_scale_inv'``.
This applies the PR's two runtime changes to the v0.29.0 files; vLLM's own ``Fp8MoEMethod`` with a
block ``Fp8Config`` serves the experts. Not applied:

  * the PR's ``has_blocked_weights`` hunk: v0.29.0's mixed config has no such method (it arrived on
    main later). That gate only picks the CUDA ``QuantFP8`` op over the native one for speed
    (vllm#25094); the MoE path quantizes its input with ``per_token_group_quant_fp8`` directly;
  * the copy of the remap in amd/mtp.py (this recipe targets GB10).

A no-op for checkpoints that are not ModelOpt MIXED_PRECISION (RadixArk and its derivatives are
quant_algo NVFP4 and carry no ``quantized_layers``). Each file is skipped when the fix is already
there, so the step survives a base image that includes vllm#55513.

usage: patch_block_fp8_mtp.py <site-packages dir>
"""
import ast
import sys

SP = sys.argv[1]
MODELOPT = f"{SP}/vllm/model_executor/layers/quantization/modelopt.py"
MTP = f"{SP}/vllm/models/qwen4_exp/nvidia/mtp.py"


def replace_once(src: str, old: str, new: str, path: str, what: str) -> str:
    n = src.count(old)
    if n != 1:
        sys.exit(f"!! {path}: expected exactly one anchor for {what}, found {n}; re-derive the backport")
    return src.replace(old, new)


def write_checked(path: str, src: str) -> None:
    ast.parse(src)
    open(path, "w").write(src)


# --- modelopt.py: block-FP8 RoutedExperts dispatch in ModelOptMixedPrecisionConfig ---------------
MO_INIT_OLD = """\
        self.w4a16_nvfp4_config = w4a16_nvfp4_config
        self.mxfp8_config = mxfp8_config
"""
MO_INIT_NEW = MO_INIT_OLD + """
        block_sizes = {
            int(layer_info.get("group_size", 128))
            for layer_info in quantized_layers.values()
            if layer_info.get("quant_algo", "").upper() in _BLOCK_FP8_MOE_ALGOS
        }
        if len(block_sizes) > 1:
            raise ValueError(
                "MIXED_PRECISION currently requires all block-FP8 MoE layers "
                f"to use one group_size, got {sorted(block_sizes)}."
            )
        block_size = next(iter(block_sizes), 128)
        self.fp8_block_config = Fp8Config(
            is_checkpoint_fp8_serialized=True,
            activation_scheme="dynamic",
            weight_block_size=[block_size, block_size],
        )
"""
MO_MOE_OLD = """\
        if isinstance(layer, RoutedExperts):
            if quant_algo == "FP8":
"""
MO_MOE_NEW = """\
        if isinstance(layer, RoutedExperts):
            if quant_algo in _BLOCK_FP8_MOE_ALGOS:
                return Fp8MoEMethod(self.fp8_block_config, layer)
            if quant_algo == "FP8":
"""
MO_HOOK = '''

# --- qwen38-flash-dgx: vllm#55513 backport, block-FP8 MoE layers in MIXED_PRECISION checkpoints ---
# ``FP8_PB_WO`` is ModelOpt's canonical 2D block-FP8 name. Early composed Qwen3.8-Flash-Next
# checkpoints used ``FP8_BLOCK_SCALES`` for the same tensor layout, so retain it as a
# checkpoint-compatibility alias. Imported at the bottom, where this module is fully initialised.
from vllm.model_executor.layers.quantization.fp8 import Fp8Config, Fp8MoEMethod  # noqa: E402

_BLOCK_FP8_MOE_ALGOS = ("FP8_PB_WO", "FP8_BLOCK_SCALES")
'''

src = open(MODELOPT).read()
if "_BLOCK_FP8_MOE_ALGOS" in src:
    print("  modelopt.py: block-FP8 MoE dispatch already present, skipping")
else:
    src = replace_once(src, MO_INIT_OLD, MO_INIT_NEW, MODELOPT, "ModelOptMixedPrecisionConfig.__init__")
    src = replace_once(src, MO_MOE_OLD, MO_MOE_NEW, MODELOPT, "the mixed config's RoutedExperts dispatch")
    write_checked(MODELOPT, src.rstrip("\n") + "\n" + MO_HOOK)
    print("  modelopt.py: block-FP8 MoE dispatch INSTALLED (FP8_PB_WO / FP8_BLOCK_SCALES -> Fp8MoEMethod)")

# --- nvidia/mtp.py: remap quantized_layers to the draft's layer indices --------------------------
MTP_FN_OLD = """\


def _remap_mtp_weight_name(name: str) -> str | None:
"""
MTP_FN_NEW = """\


def _remap_quantized_layers(
    quantized_layers: dict[str, dict],
    mtp_start_layer_idx: int,
) -> dict[str, dict]:
    \"\"\"Map checkpoint MTP layer indices to standalone draft indices.\"\"\"
    return {
        _remap_ignored_layers([name], mtp_start_layer_idx)[0]: layer_info
        for name, layer_info in quantized_layers.items()
    }
""" + MTP_FN_OLD
MTP_CALL_OLD = """\
        exclude_modules = getattr(draft_quant_config, "exclude_modules", None)
        if exclude_modules:
            setattr(  # noqa: B010
                draft_quant_config,
                "exclude_modules",
                _remap_ignored_layers(exclude_modules, mtp_start_layer_idx),
            )
"""
MTP_CALL_NEW = MTP_CALL_OLD + """\
        # qwen38-flash-dgx: vllm#55513 backport
        quantized_layers = getattr(draft_quant_config, "quantized_layers", None)
        if quantized_layers:
            setattr(  # noqa: B010
                draft_quant_config,
                "quantized_layers",
                _remap_quantized_layers(quantized_layers, mtp_start_layer_idx),
            )
"""

src = open(MTP).read()
if "_remap_quantized_layers" in src:
    print("  nvidia/mtp.py: quantized_layers remap already present, skipping")
else:
    src = replace_once(src, MTP_FN_OLD, MTP_FN_NEW, MTP, "_remap_mtp_weight_name")
    src = replace_once(src, MTP_CALL_OLD, MTP_CALL_NEW, MTP, "the exclude_modules remap in _make_draft_vllm_config")
    write_checked(MTP, src)
    print("  nvidia/mtp.py: quantized_layers remap INSTALLED (mtp.layers.0 -> mtp.layers.<num_hidden_layers>)")

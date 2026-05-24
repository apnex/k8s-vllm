# Audit D — code diff v0.20.2..v0.21.0

**Date:** 2026-05-24
**Auditor:** subagent D (5-of-5 parallel)
**Commits in range:** 396 (per `git log --oneline v0.20.2..v0.21.0 | wc -l`)
**Files changed:** 1096 (+103,496 / −45,423 — per `git diff --stat | tail -1`)

---

## TL;DR (top 3 surgical findings for our config)

1. **Three default env-var flips that change generation behaviour silently on a bumped image tag:**
   - `VLLM_USE_FLASHINFER_SAMPLER`: `None` (opt-in) → `True` (opt-out). Top-k/top-p sampling now goes through FlashInfer by default; falls back to native sampler with a `warning_once` if FlashInfer doesn't support the compute capability. RTX 5090 (sm_120) needs verification — it falls back silently if unsupported, so behaviour stays similar, but accuracy/perf characteristics shift if it IS supported.
   - `VLLM_ENABLE_PREGRAD_PASSES`: `False` → `True`. Adds ~1s to cold compile time. Comment in code: "maybe_inplace requires this".
   - `VLLM_USE_RAY_V2_EXECUTOR_BACKEND`: `0` → `1`. Only matters if `distributed_executor_backend="ray"` (not our case).

2. **`vllm/tool_parsers/abstract_tool_parser.py` adds a new structural-tag enforcement code path** gated by the new env var `VLLM_ENFORCE_STRICT_TOOL_CALLING` (default `False`). When set, parsers like `Qwen3CoderToolParser` (which now declares `supports_required_and_named = False`) push a `structural_tag` into the `StructuredOutputsParams` and bypass the legacy JSON-schema path. With the env var off, default behaviour is preserved — but the parser surface area for our `--tool-call-parser` choice has visibly shifted; the `extract_tool_call_required_streaming` static method in `chat_completion/serving.py` was deleted (replaced by `DelegatingParser` per commit `8eb401134`), so any custom override that called it will break.

3. **Speculative-decoding API renamed:** `RejectionSampleMethod` literal `"strict"`/`"probabilistic"` collapsed to `"standard"`; the `speculative_token_tree: str | None` field was removed entirely. We don't use spec decode today, but if we ever try `--speculative-config`, prior YAML snippets from the wild will fail Pydantic validation.

Combined with the cuDNN-prefill removal (MLA-only path, irrelevant for our dense Qwen/Llama models), the dynamic-arg-dims schema change (compile-config internal — no user-visible impact), and the new `xgrammar >= 0.2.0` requirement (major bump on the structured-outputs dependency), this is a substantial release for any user with auto-tool-choice + grammar-based generation.

---

## Top-level shape

Mass concentration (top contributors to the 1096-file / 148k-line diff):

| Lines | File | Note |
|------:|------|------|
| 29,487 | `helion/configs/silu_mul_fp8/nvidia_h{100,200}.json` | Auto-tuned kernel configs (H100/H200) — no Blackwell config added |
| 1,488 | `vllm/model_executor/models/mimo_v2_omni.py` | New model (Xiaomi MiMo V2 Omni) |
| 1,423 | `vllm/model_executor/models/moondream3.py` | New model |
| 1,394 | `csrc/cpu/sgl-kernels/fla.cpp` | New CPU SGL kernel |
| 1,389 | `vllm/model_executor/models/mimo_audio.py` | New model |
| 1,056 | `routed_experts_capturer.py` (fused_moe) | Routed-experts capturing infra; powers the new `routed_experts` field on `ChatCompletionResponse` |
| 979 | `kv_transfer/.../mooncake/store/worker.py` | Mooncake KV-store worker |
| 902 | `vllm/model_executor/models/laguna.py` | New model |
| 583 | `vllm/tool_parsers/poolside_v1_tool_parser.py` | New tool parser |
| 565 | `vllm/reasoning/cohere_command_reasoning_parser.py` | New reasoning parser |
| 506 | `tests/v1/spec_decode/test_tree_attention.py` (DELETED) | `TREE_ATTN` backend removed |
| 492 | `vllm/model_executor/layers/fused_moe/fused_moe.py` (DELETED) | Replaced by `experts/` subdir |

What dominates the diff: new models (MiMo V2 family, Moondream3, Laguna, Cohere2-MoE), new tool parsers (Cohere Command, Poolside, LFM2), MLA prefill backend abstraction, fused-MoE refactor into `experts/` subdir, and KV-transfer / disaggregated-serving plumbing. The model loaders for our families (Qwen3, Llama, Gemma3) saw minimal, defensive changes.

---

## Per-focus-path findings

### Model loaders (qwen3, qwen2, llama, gemma3)

**`vllm/model_executor/models/qwen3.py`** — *no diff*. Identical between v0.20.2 and v0.21.0.

**`vllm/model_executor/models/qwen2.py`** — Inlined a removed shape-invariants helper. The change replaces `int` axis specifiers with `{axis: name}` dicts:

```python
-        "input_ids": 0,
-        "positions": -1,
-        "intermediate_tensors": 0,
-        "inputs_embeds": 0,
-    },
-    shape_invariants=qwen_2_model_invariants,
+        "input_ids": {0: "b"},
+        "positions": {-1: "b"},
+        "intermediate_tensors": {0: "b"},
+        "inputs_embeds": {0: "b"},
+    }
```

This is a `torch.compile` plumbing change — the named symbolic dim "b" lets the compiler tie multiple dynamic dims together. No runtime behaviour change for inference, but custom subclasses that passed `shape_invariants=` will break.

**`vllm/model_executor/models/llama.py`** — Same `shape_invariants` → `dynamic_arg_dims` migration as qwen2. Helper `llama_model_invariants` deleted.

**`vllm/model_executor/models/gemma3.py`** — Activation lookup replaced with the registry call:

```python
-        if hidden_activation != "gelu_pytorch_tanh":
-            raise ValueError(
-                "Gemma3 uses `gelu_pytorch_tanh` as the hidden activation "
-                "function. Please set `hidden_act` and `hidden_activation` to "
-                "`gelu_pytorch_tanh`."
-            )
-        self.act_fn = GeluAndMul(approximate="tanh")
+        self.act_fn = get_act_and_mul_fn(hidden_activation)
```

Net effect: Gemma3 no longer hard-fails on non-`gelu_pytorch_tanh` `hidden_activation` configs, and other activations from the registry (`gelu`, `silu`, `swish`, `geglu`, `swigluoai`) silently work — relevant for community-quantized Gemma3 derivatives that set the field differently. The new `_ACTIVATION_AND_MUL_REGISTRY` entry `"gelu_pytorch_tanh": lambda: GeluAndMul(approximate="tanh")` keeps the canonical path identical to before.

**`vllm/model_executor/models/qwen2_5_vl.py`** (+438 net) — substantial multimodal-encoder updates; tangential to our dense-text use case.

**`vllm/model_executor/models/qwen3_vl.py`** (+9 net) — adds FP8-attention padding hook in the vision transformer (`get_fp8_padded_hidden_size`); only matters with `--mm-encoder-attn-dtype=fp8`, which is new in v0.21.0 (see Multimodal section).

**`vllm/model_executor/models/qwen3_moe.py`** — *no diff*.

**`vllm/model_executor/models/qwen3_next.py`** (+30 net) — All changes gated on `rocm_aiter_ops.is_fusion_moe_shared_experts_enabled()`. ROCm-only; no impact on our CUDA build.

**`vllm/model_executor/models/llama4.py`**, **`qwen2_moe.py`**, **`gemma3n.py`** — moderate diffs but irrelevant for our target model families (we run dense Qwen3 / Llama-3 / Gemma-3-4B).

### AWQ quantization kernels

**`vllm/model_executor/layers/quantization/awq.py`** — *no diff*.
**`vllm/model_executor/layers/quantization/awq_triton.py`** — *no diff*.
**`vllm/model_executor/layers/quantization/awq_marlin.py`** — 2 import-path updates only:

```python
-from vllm.model_executor.layers.fused_moe.fused_marlin_moe import fused_marlin_moe
+from vllm.model_executor.layers.fused_moe.experts.marlin_moe import fused_marlin_moe
-        from vllm.model_executor.layers.fused_moe.fused_marlin_moe import (
+        from vllm.model_executor.layers.fused_moe.experts.marlin_moe import (
             BatchedMarlinExperts,
             MarlinExperts,
         )
```

This is the `[MoE] Move various experts classes to fused_moe/experts/` refactor (#41979). No kernel-dispatch change; the file `vllm/model_executor/layers/fused_moe/fused_moe.py` was deleted and replaced by per-expert modules under `experts/`. External plugins that imported from `fused_marlin_moe` will break.

**Bottom line for AWQ on Blackwell:** no kernel changes that affect AWQ-int4 dense linear (our serving path). The Marlin MoE shuffle is unchanged. The dispatch matrix that selects AWQ-Marlin vs AWQ-Triton vs AWQ-base is identical to v0.20.2 for dense models.

### Attention backends

**`vllm/v1/attention/backends/registry.py`** — added `TOKENSPEED_MLA` enum value, removed `TREE_ATTN`, removed the `MAMBA_TYPE_TO_BACKEND_MAP` shim:

```python
+    TOKENSPEED_MLA = (
+        "vllm.v1.attention.backends.mla.tokenspeed_mla.TokenspeedMLABackend"
+    )
...
-    TREE_ATTN = "vllm.v1.attention.backends.tree_attn.TreeAttentionBackend"
```

**`vllm/v1/attention/selector.py`** — the `use_non_causal` flag is no longer derived from speculative config inside the selector; it now reads from `vllm_config.attention_config.use_non_causal`. Configs that supplied `use_non_causal` via `speculative.method == "dflash"` only will keep working through migration logic in `config/speculative.py`; configs that hand-edited the field elsewhere need re-checking.

**MLA prefill backend abstraction (commit `f3fef1235`)** — `use_cudnn_prefill` is now deprecated and the cuDNN MLA prefill backend was removed. New unified `mla_prefill_backend` enum:

```python
-    use_cudnn_prefill: bool = False
-    """Whether to use cudnn prefill."""
+    use_cudnn_prefill: bool = False
+    """Deprecated: cuDNN prefill backend has been removed."""
...
-    disable_flashinfer_prefill: bool = True
+    disable_flashinfer_prefill: bool | None = None
...
+    mla_prefill_backend: MLAPrefillBackendEnum | None = None
+    """MLA prefill backend to use. If None, will be selected automatically.
+    Valid options: FLASH_ATTN (FA3/FA4), FLASHINFER, TRTLLM_RAGGED."""
```

We don't run MLA-architecture models (DeepSeek-V3 etc.), so this is informational. Default behaviour preserved for non-MLA models.

**Blackwell (`vllm/platforms/cuda.py`)** — only two changes:

```python
             return [
                 AttentionBackendEnum.FLASHINFER_MLA,
+                # R1 dims + FP8 KV only; rejected by supports_combination
+                # otherwise. Behind FLASHINFER_MLA: wins past bs≈8, regresses
+                # at bs≤2.
+                AttentionBackendEnum.TOKENSPEED_MLA,
                 AttentionBackendEnum.CUTLASS_MLA,
```
and
```python
-        return IrOpPriorityConfig.with_default(default, rms_norm=rms_norm)
+        return IrOpPriorityConfig.with_default(
+            default, rms_norm=rms_norm, fused_add_rms_norm=rms_norm
+        )
```

Neither touches the dense-model attention selection path on sm_120. The MLA prio list only applies for MLA architectures. The `fused_add_rms_norm` IR-pass change applies to all CUDA platforms — should be a no-op functionally but adds a new IR fusion candidate.

### OpenAI server entrypoints

**`vllm/entrypoints/openai/api_server.py`** (+15 lines) — adds a contextvar bridge so tool parsers running in the API-server process can see `enable_in_reasoning`:

```python
+    from vllm.tool_parsers.structural_tag_registry import (
+        set_enable_structured_outputs_in_reasoning,
+    )
+    set_enable_structured_outputs_in_reasoning(
+        vllm_config.structured_outputs_config.enable_in_reasoning
+    )
```

**`vllm/entrypoints/openai/chat_completion/protocol.py`** — many additions to `ChatCompletionResponse` / `ChatCompletionRequest`:

- New response field `prompt_routed_experts: list[list[list[int]]] | None` (MoE-only, populated by `routed_experts_capturer`).
- New choice field `routed_experts: list[list[list[int]]] | None`.
- New response field `prompt_text: str | None` (rendered chat template — gated by request `return_prompt_text`).
- New request field `return_prompt_text: bool | None`.
- `reasoning_effort` literal expanded from `["none","low","medium","high"]` → `["none","minimal","low","medium","high","xhigh","max"]`. Old clients sending `"medium"` continue to work; new values cause validation errors on the *old* server, so this is forward-compatible only.
- New stream-final-chunk `system_fingerprint: str | None` (driven by `--fingerprint-mode`).
- `ChatCompletionToolsParam` gains a `defer_loading: bool | None` field with a `model_serializer` to suppress the key when unset (zero serialized-size impact when unused).

**`vllm/entrypoints/openai/chat_completion/serving.py`** (-367 net of churn) — wraps the main handler in a new `_with_kv_transfer_rejection_cleanup` outer that calls `notify_kv_transfer_request_rejected` on the engine when a request is rejected pre-admission; deletes the legacy `_bracket_level`, `_filter_delta_text`, `extract_tool_call_required_streaming` helpers. Behaviour change: required-tool-choice streaming now goes through per-parser `DelegatingParser` logic instead of the inline JSON-bracket walker. Should be functionally equivalent for any parser already in-tree but third-party parsers that subclassed `OpenAIServingChat` to override these statics will silently no-op.

Also a small bugfix that's user-visible:

```python
                 self.default_sampling_params,
                 self.override_max_tokens,
+                truncate_prompt_tokens=request.truncate_prompt_tokens,
             )
```

`truncate_prompt_tokens` now feeds into max-tokens computation (#41800) — previously, requests with `truncate_prompt_tokens` set could over-allocate `max_tokens`.

**`vllm/entrypoints/openai/cli_args.py`** — new flags:

```python
+    fingerprint_mode: Literal["full", "hash", "custom", "none"] = "full"
+    fingerprint_value: str | None = None
```

Default `"full"` emits `vllm-<version>[-<parallelism>]-<hash8>` as the `system_fingerprint` response field. Monitoring/dashboards that parse `system_fingerprint` will see the field appear/change shape if they previously got `null`. To preserve old behaviour: `--fingerprint-mode=none`.

**`vllm/entrypoints/openai/responses/serving.py`** (−635 net) — large refactor of the Responses API; pre-existing handler logic split out. Not used by our setup.

### Tool-call parsers

**Layout:** `vllm/tool_parsers/` is the canonical location in both v0.20.2 and v0.21.0; `vllm/entrypoints/openai/tool_parsers/` does *not* exist in either tag. The release-note phrasing about "moved tool parsers" predates v0.20.2.

**`vllm/tool_parsers/abstract_tool_parser.py`** — the big behavioural change: `adjust_request()` gains a structural-tag fast-path before the JSON-schema path:

```python
+        if (
+            isinstance(request, ChatCompletionRequest)
+            and VLLM_ENFORCE_STRICT_TOOL_CALLING
+        ):
+            need_tool_calling = (
+                request.tool_choice == "auto"
+                or request.tool_choice == "required"
+                or isinstance(request.tool_choice, ChatCompletionNamedToolChoiceParam)
+            )
+            if need_tool_calling:
+                structure_tag = self.get_structural_tag(request)
+                if structure_tag is not None:
+                    if request.structured_outputs is None:
+                        request.structured_outputs = StructuredOutputsParams(
+                            structural_tag=json.dumps(structure_tag.model_dump()),
+                        )
+                    else:
+                        request.structured_outputs.structural_tag = json.dumps(
+                            structure_tag.model_dump()
+                        )
+                    return request
```

Gated on the new env var `VLLM_ENFORCE_STRICT_TOOL_CALLING=1`. Default-off, so our current `--enable-auto-tool-choice` runs identically to v0.20.2 unless we opt in. Also adds default `get_structural_tag(self, request) -> None` for parsers that don't implement it.

**`vllm/tool_parsers/qwen3coder_tool_parser.py`** — the only Qwen-family parser with a behaviour change:

```python
 class Qwen3CoderToolParser(ToolParser):
+    supports_required_and_named: bool = False
```

This routes `tool_choice="required"` and named-function `tool_choice` away from the standard JSON-grammar path and into the `DelegatingParser` flow, which means it relies on the structural-tag path (when `VLLM_ENFORCE_STRICT_TOOL_CALLING=1`) or on the auto-tool fallback (when off). For users with auto-only tool choice, no behaviour change. For users issuing `tool_choice={"type":"function","function":{"name":"..."}}` against the Qwen3-Coder parser, the streaming path now differs.

Also adds `get_structural_tag()`:
```python
+    def get_structural_tag(self, request: ChatCompletionRequest):
+        return get_model_structural_tag(
+            model="qwen_3_5",
+            tools=request.tools,
+            tool_choice=request.tool_choice,
+            reasoning=get_enable_structured_outputs_in_reasoning(),
+        )
```

**`vllm/tool_parsers/qwen3xml_tool_parser.py`** — *no diff*.
**`vllm/tool_parsers/llama_tool_parser.py`** — *no diff* (per our `git diff` enumeration; the file exists unchanged at v0.21.0 with hash matching grep above).
**`vllm/tool_parsers/gemma4_tool_parser.py`** — +19 lines (bugfix per commit `dbd86a67e`: "Fix infinite loop and array boundary issues").
**`vllm/tool_parsers/glm4_moe_tool_parser.py`** — small whitespace-preservation fix.
**`vllm/tool_parsers/mistral_tool_parser.py`** — +50 lines.

**New parsers registered:**
- `cohere_command_tool_parser.py` (+127)
- `poolside_v1_tool_parser.py` (+583)
- `lfm2_tool_parser.py` (+343)

**New shared infra:**
- `vllm/tool_parsers/structural_tag_registry.py` (+330 new file) — defines `get_model_structural_tag()`, `get_enable_structured_outputs_in_reasoning()` / `set_enable_structured_outputs_in_reasoning()`.
- `vllm/tool_parsers/streaming.py` (+195 new file) — shared streaming helpers.
- `vllm/tool_parsers/__init__.py` re-exports gain 16 lines (new parser names).

### Engine v1 / v0

**No default flip between v0 and v1.** Both tags already default to the V1 engine. v0.21.0 adds a `notify_kv_transfer_request_rejected()` path and the two-phase DP pause/resume protocol on `DPEngineCoreProc` (commit `3f5bd482f`). Single-GPU users (us) are unaffected by either.

**`vllm/v1/engine/core.py`** — `EngineCore.add_request()` gains:
```python
+        if request.abort_immediately:
+            self.abort_requests([request.request_id])
```
This is the receiver side of the new "abort_immediately" semantic used by the KV-rejection cleanup path. Backward compatible — old code paths never set `abort_immediately=True`.

**`vllm/v1/engine/async_llm.py`** — new RPCs: `start_weight_update()`, `finish_weight_update()`, `notify_kv_transfer_request_rejected()`. RL-training plumbing.

### CLI args / config

**EngineArgs additions (`vllm/engine/arg_utils.py`):**

```
--safetensors-prefetch-num-threads INT  (default 8)
--safetensors-prefetch-block-size BYTES (default 16 MiB)
--mm-encoder-attn-dtype {fp8}
--mm-encoder-fp8-scale-path PATH
--mm-encoder-fp8-scale-save-path PATH
--mm-encoder-fp8-scale-save-margin FLOAT (default 1.5)
```

**Behaviour change for `--hf-token`:** the special-cased argparse registration (with explicit `nargs="?"`, `const=True`) was deleted in favour of generic handling via the new `Optional[bool|str|None]` type-hint path. Net effect should be identical, but the order of CLI-help output for `--hf-token` differs.

**Hard-fail added for non-MoE + `--data-parallel-rank`:**
```python
+        if (
+            self.data_parallel_size > 1
+            and data_parallel_external_lb
+            and not model_config.is_moe
+        ):
+            raise ValueError(
+                "Non-MoE models do not support external data parallel mode. "
+                "For external load balancing, launch independent vLLM "
+                "instances without --data-parallel-* arguments."
+            )
```

Doesn't affect us (single GPU), but worth noting.

**TurboQuant `kv_cache_dtype_skip_layers` boundary protection** was simplified — the hybrid-model assertion that previously rejected (attention+Mamba) models with `--kv-cache-dtype=turboquant_*` was removed; the boundary skip is now derived from `model_config` directly. Doesn't affect us (we don't use turboquant KV).

**`vllm/config/load.py`** — new fields with sane defaults:
```python
+DEFAULT_SAFETENSORS_PREFETCH_NUM_THREADS = 8
+DEFAULT_SAFETENSORS_PREFETCH_BLOCK_SIZE = 16 * 1024 * 1024
```

**`vllm/config/model.py`** — `TokenizerMode` literal gained `"fastokens"` (Rust BPE backend via the `fastokens` package — optional dep). Reordered `model_arch_config` initialisation to happen before `hf_image_processor_config` — should be transparent.

**`vllm/config/multimodal.py`** — adds the `mm_encoder_attn_dtype`/`mm_encoder_fp8_*` fields documented above, plus validators that raise `FileNotFoundError` on missing FP8 scale-file paths.

**`vllm/config/speculative.py`** — the biggest API-shape change in the release for spec-decode users:

- `RejectionSampleMethod = Literal["strict", "probabilistic", "synthetic"]` → `Literal["standard", "synthetic"]`. The old `"strict"`/`"probabilistic"` values are *no longer accepted*.
- Default value: `"strict"` → `"standard"`.
- Field `speculative_token_tree: str | None = None` was *removed* entirely.
- New field `draft_sample_method: Literal["greedy", "gumbel"] = "greedy"` (Model Runner V2 only).
- New field `attention_backend: AttentionBackendEnum | None = None` (for picking the draft model's attention backend independently).
- New MTP architectures registered: `mimo_v2_mtp`, `gemma4_mtp`.

**`vllm/config/attention.py`** — cuDNN prefill deprecated (see Attention section). New `use_non_causal` field. New `mla_prefill_backend` field. Old `disable_flashinfer_prefill: bool = True` → `bool | None = None` (auto-detect by default).

### CUDA platform detection

`vllm/platforms/cuda.py` — only the two snippets shown in the Attention section. Capability detection logic for Blackwell (sm_120) is unchanged from v0.20.2. There is no new code path that gates on sm_120 or sm_100 specifically that would affect us.

### Dockerfile / image

**Python install:** `docker/Dockerfile` (vllm-base stage) abandons the source-build of CPython in favour of deadsnakes:

```diff
-    && PYTHON_FULL_VERSION=$(curl -s https://www.python.org/ftp/python/ \
-        | grep -oE "${PYTHON_MAJOR_MINOR}\.[0-9]+" ...
-    && echo "Building Python ${PYTHON_FULL_VERSION} from source..." \
-    && ./configure --enable-optimizations --with-ensurepip=install --prefix=/usr/local \
-    && make -j$(nproc) \
-    && make install \
...
+        software-properties-common \
+        ... \
+    && add-apt-repository -y ppa:deadsnakes/ppa ... \
+    && apt-get install -y --no-install-recommends \
+        python${PYTHON_VERSION} \
+        python${PYTHON_VERSION}-dev \
+        python${PYTHON_VERSION}-venv \
```

Faster builds, smaller install footprint. The Python interpreter is now a PPA build instead of a `--enable-optimizations` from-source build (slight perf difference in pure-Python paths — usually negligible).

**Multi-OS build base:** new `BUILD_OS={ubuntu,manylinux}` ARG. The manylinux path uses `dnf` and pre-installed `/opt/python/cpXY-cpXY/`. Default stays `ubuntu`.

**`libcublas` → `libcublas-dev`:**
```diff
-        libcublas-${CUDA_VERSION_DASH} \
+        libcublas-dev-${CUDA_VERSION_DASH} \
```
Adds the dev package (headers + .so symlinks). Image gains a few hundred MB but JIT-compiled paths now have headers available at runtime.

**FlashInfer cubin download reordered:**
```diff
-    uv pip install --system flashinfer-jit-cache==${FLASHINFER_VERSION} \
-        --extra-index-url https://flashinfer.ai/whl/cu... \
-    && flashinfer show-config \
-    && flashinfer download-cubin
+    uv pip install --system flashinfer-jit-cache==${FLASHINFER_VERSION} \
+        --extra-index-url https://flashinfer.ai/whl/cu...
+
+# Download FlashInfer precompiled cubins AFTER all pip installs are done.
+RUN flashinfer show-config && flashinfer download-cubin
```

Comment in the new code says this saves ~2.5 GB of layer duplication when later pip installs overwrite flashinfer package files. Image is smaller.

**FlashInfer version:** `FLASHINFER_VERSION=0.6.8.post1` is the same default ARG value as v0.20.2, but `flashinfer-jit-cache` may pull a different runtime depending on extra-index resolution.

**NIXL install change:** the explicit `nixl-cu13` branch was removed; now unconditionally `--force-reinstall --no-deps nixl-cu${CUDA_MAJOR}`. Only affects KV-connector image variants.

**DeepGEMM multi-Python provisioning:** new tools/setup_deepgemm_pythons.sh; iterates the `requires-python` matrix from pyproject and builds DeepGEMM `_C` once per supported CPython. Image-build-time only.

**OCI labels:** new `LABEL org.opencontainers.image.{source,revision,version,url}` and `ai.vllm.build.{commit,pipeline,url,image.tag}`. Useful for image-provenance tooling.

**`examples/online_serving/sagemaker-entrypoint.sh` → `examples/deployment/sagemaker-entrypoint.sh`** — path rename inside the image.

**Python deps (`requirements/common.txt`, `requirements/cuda.txt`):**

| pkg | v0.20.2 | v0.21.0 |
|---|---|---|
| xgrammar | `>= 0.1.32, < 1.0.0` | `>= 0.2.0, < 1.0.0` |
| mistral_common[image] | `>= 1.11.0` | `>= 1.11.2` |
| model-hosting-container-standards | `>= 0.1.13, < 1.0.0` | `>= 0.1.14, < 1.0.0` |
| nvidia-cutlass-dsl | `>= 4.4.2` | `== 4.4.2` (pinned) |
| tokenspeed-mla | absent | `== 0.1.2` |

**xgrammar 0.1.32 → 0.2.0 is a major-version bump on the structured-outputs library.** Anyone using `--guided-decoding-backend=xgrammar` (or its inherited use via structural-tag enforcement) will pick up the 0.2.0 API. Known breaking changes from upstream xgrammar 0.2.0 release notes are not in scope for this audit, but consumers of guided-JSON should test.

**`nvidia-cutlass-dsl` pinned:** `>= 4.4.2` → `== 4.4.2` removes the floor flexibility. Also, `setup.py` now strips the `[cu13]` extra on CUDA-12 builds, and the Dockerfile mirrors this via `sed -i 's/^nvidia-cutlass-dsl\[cu13\]>=/nvidia-cutlass-dsl>=/'`. This means CUDA-13 base images get a *different* cutlass-dsl wheel than CUDA-12 — verify the published `vllm/vllm-openai:v0.21.0` tag matches your CUDA stage.

**`tokenspeed-mla == 0.1.2` is a new mandatory CUDA dep** (it's in `requirements/cuda.txt`, not gated). The package is for the new `TOKENSPEED_MLA` attention backend for DeepSeek-R1/Kimi-K25 — useless for our dense Qwen models, but you pay the install size.

---

## Surgical breakages for our config

Things that would specifically bite us on a naïve `image: vllm/vllm-openai:v0.21.0` swap:

1. **Sampler default change is silent.** `VLLM_USE_FLASHINFER_SAMPLER` default-on means our greedy paths still produce the same tokens, but stochastic paths (`temperature>0`, `top_k`, `top_p`) may produce slightly different tokens vs. v0.20.2 if sm_120 is supported by FlashInfer (and our determinism guarantees, if we rely on any, change). If FlashInfer rejects sm_120, we get a one-time `warning_once` in logs and fall through to the same native sampler we used before.

   ```python
   +                else:
   +                    # Default-on path; hardware can't run FlashInfer →
   +                    # quietly fall back to the PyTorch-native sampler
   +                    logger.warning_once(
   +                        "FlashInfer top-p/top-k sampling not supported on "
   +                        "compute capability %s; falling back to PyTorch-native "
   +                        "sampler. Set VLLM_USE_FLASHINFER_SAMPLER=0 to silence.",
   ```

   **Mitigation:** explicitly set `VLLM_USE_FLASHINFER_SAMPLER=0` in the container env to preserve v0.20.2 behaviour while we soak.

2. **`VLLM_ENABLE_PREGRAD_PASSES=1` default** adds ~1s to cold-compile time per the inline comment. Imperceptible for steady-state serving, marginal for the cold-load gap we already track.

3. **`Qwen3CoderToolParser.supports_required_and_named=False`** changes the streaming path for `tool_choice="required"` and named-function tool_choice. If we drive Qwen3-Coder with `tool_choice="auto"` (default), no impact. If we use `tool_choice="required"`, the streaming framing now goes through `DelegatingParser` instead of the inline bracket-walker — verify with our integration tests.

4. **`xgrammar` major bump** affects any guided-JSON request path. Test with our actual tool-call payloads.

5. **`system_fingerprint` field is now present** by default on response bodies. Monitoring code that asserted `body.system_fingerprint is None` will break. The new value looks like `vllm-0.21.0-<hash8>`. Set `--fingerprint-mode=none` to opt out.

6. **`prompt_text` / `prompt_routed_experts` / `routed_experts` fields appear** in `ChatCompletionResponse` — they're `None` by default and only populated when explicitly requested, but Pydantic-strict clients that built response schemas off the v0.20.2 model class will fail validation against responses generated by v0.21.0 servers.

7. **`reasoning_effort` literal expanded** to include `minimal`, `xhigh`, `max`. If we pin our request bodies through a Pydantic schema dumped from `openai` upstream that hasn't been updated, the schema validation is forward-compatible. Old vLLM clients sending `"medium"` keep working.

8. **`--data-parallel-rank` now hard-rejects non-MoE models.** Doesn't affect us.

9. **`vllm/model_executor/layers/fused_moe/fused_moe.py` deleted** — third-party code that imports `from vllm.model_executor.layers.fused_moe.fused_moe import ...` (including older AWQ marlin wrappers) will fail. Pure consumers via `--quantization=awq` are unaffected.

10. **The deleted `extract_tool_call_required_streaming` static** in `OpenAIServingChat` — if any custom tool parser or middleware called it via `OpenAIServingChat.extract_tool_call_required_streaming(...)`, it now raises `AttributeError`.

11. **Image size:** new mandatory `tokenspeed-mla` wheel + `libcublas-dev`. Pull-time bandwidth and disk footprint both up; not big.

12. **TLS / monitoring:** the dockerfile gained `software-properties-common` to bootstrap deadsnakes-PPA. If we run the image in a network-isolated environment where the PPA mirror isn't reachable at install time, the build will fail — but this is a build-time, not runtime, concern. Our use is a prebuilt image, so transparent.

---

## Default flips worth knowing about

| Flag / env var | v0.20.2 default | v0.21.0 default | Applies to us? |
|---|---|---|---|
| `VLLM_USE_FLASHINFER_SAMPLER` | `None` (opt-in) | `True` | **Yes** — sampler path |
| `VLLM_ENABLE_PREGRAD_PASSES` | `False` | `True` | Yes — cold compile +~1s |
| `VLLM_USE_RAY_V2_EXECUTOR_BACKEND` | `0` | `1` | No (we don't use Ray) |
| `VLLM_ENFORCE_STRICT_TOOL_CALLING` | n/a | `False` (new) | No unless we opt in |
| `VLLM_SKIP_MODEL_NAME_VALIDATION` | n/a | `False` (new) | No unless we opt in |
| `--fingerprint-mode` | n/a | `"full"` (new) | **Yes** — response shape |
| `AttentionConfig.disable_flashinfer_prefill` | `True` | `None` (auto) | No (MLA-only setting) |
| `SpeculativeConfig.rejection_sample_method` | `"strict"` | `"standard"` | No (no spec decode) |
| `SpeculativeConfig.speculative_token_tree` | `None` (field present) | **field removed** | No (no spec decode) |
| `IrOpPriorityConfig.fused_add_rms_norm` | absent | `rms_norm` priority | All CUDA — should be no-op |

---

## Risk score for our use case (1-5)

**3 / 5 — moderate**.

Justification:
- Our core path (Qwen3 dense + AWQ + OpenAI server + auto-tool-choice + single sm_120 GPU + 98K context) intersects with **four** v0.21.0 changes that have real semantic content: FlashInfer-sampler default flip, structural-tag enforcement option, deleted tool-parser streaming helpers (via the Qwen3-Coder `supports_required_and_named=False` flag), and `xgrammar` 0.2.0.
- None of those four changes will *crash* our deployment.
- Two of those four will *silently* change response content vs. v0.20.2 (sampler determinism on stochastic decode; system_fingerprint field). Both are mitigable by a one-line env-var or CLI-flag override.
- The Qwen3 / Llama3 / Gemma3 model loaders themselves are essentially unchanged (compile-decorator schema tweaks aside).
- No Blackwell-specific code paths regressed; the new Blackwell additions (`TOKENSPEED_MLA`, faster FP8 group-quant kernel) are MLA-only and don't affect us.
- The big Dockerfile rebuild changes the Python interpreter source (deadsnakes vs from-source) and reorders FlashInfer cubin download — image is more reproducible and ~2.5 GB smaller, no runtime regression expected.

Bumping the image tag with the following two env-var overrides in our container spec would land safely:
```
VLLM_USE_FLASHINFER_SAMPLER=0
# and optionally:
# --fingerprint-mode=none  (added to the vllm serve invocation)
```

---

## Open questions for consolidation

1. **Does FlashInfer 0.6.8.post1 actually support sm_120 sampling kernels?** The `FlashInferBackend.supports_compute_capability(120)` call is the gate. If FlashInfer claims support but the kernel produces NaN/Inf on sm_120, we'd hit a regression that's invisible until output quality drops. Worth a quick `VLLM_USE_FLASHINFER_SAMPLER=1 vs =0` A/B on a known prompt set.

2. **Does `xgrammar 0.2.0` break our existing tool-call grammars?** Specifically the JSON-schema templates our Qwen3 / Llama3 parsers produce. Easiest verification: pin `vllm==0.21.0` in a sandbox, send one of each tool-call test case, compare token-level output to v0.20.2.

3. **Was the `unsetup-able` `nvidia-cutlass-dsl==4.4.2` pin coordinated with the CUDA-12 vs CUDA-13 image variants?** Setup.py strips `[cu13]` for CUDA-12 builds, but the version is pinned to a single `4.4.2`. If the upstream `nvidia-cutlass-dsl` 4.4.2 wheel for CUDA-12 has a different ABI than CUDA-13, the prebuilt image may or may not match what our nvbandwidth/diag container expects.

4. **Are the new `routed_experts` / `prompt_routed_experts` MoE response fields ever populated for dense Qwen3 models?** They should be `None` always, but if the routed-experts-capturer infra is wired into the general response path, there's a non-zero chance dense models pay even a small serialisation overhead. Worth a `wc -c` of one response body comparing v0.20.2 vs v0.21.0.

5. **Cross-check with subagent A's CHANGELOG findings** — specifically whether v0.21.0 ships any tokenizer / chat-template default changes for Qwen3 that *aren't* visible in the Python source diff (e.g., bundled chat-template JSON updates under `examples/` or `docs/`).

6. **Cross-check with subagent C** — any of the last-30-days bug themes touching the FlashInfer sampler, structural-tag enforcement, or Qwen3-Coder required-tool-choice should be elevated as v0.21.0-specific regressions given the default flips above.

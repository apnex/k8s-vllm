# k8s-vllm

vLLM OpenAI-compatible inference server, deployed as a consumer of the [`nvidia-driver-injector`](https://github.com/apnex/nvidia-driver-injector) producer.

**Status:** in production.\
Pinned to `vllm/vllm-openai:v0.20.2`.\
v0.21.0 is intentionally skipped — see [`audit/v0.21.0/CONSOLIDATED.md`](audit/v0.21.0/CONSOLIDATED.md).

## Install

Two supported paths share `Layer 1`-`Layer 2` host bring-up (the driver injector) and diverge at `Layer 3` (how the workload is scheduled).

Verify the producer is healthy first:
```bash
cat /sys/module/nvidia/version       # 595.71.05-aorus.<n>
nvidia-smi -L                        # lists the GPU
```

Clone this repo:
```bash
git clone https://github.com/apnex/k8s-vllm /root/k8s-vllm
cd /root/k8s-vllm
```

### Path A — docker-compose (dev / single-host)

```bash
docker compose up -d
docker compose logs -f               # watch model load (~1-2 min cold with cache)
```

The compose file pins `vllm/vllm-openai:v0.20.2` and binds the HF cache at `/root/.cache/huggingface`.\
Override the model via `.env` (gitignored) — see [`docker-compose.yml`](docker-compose.yml) for variables.

### Path B — k3s Deployment (recommended for production)

```bash
kubectl apply -f k8s/
kubectl -n vllm rollout status deployment/vllm
```

The workload gates on labels published by the driver injector — `nodeSelector: nvidia.driver/state=ready` + `runtimeClassName: nvidia` + `env: NVIDIA_VISIBLE_DEVICES=all`.\
Full apply / verify / port-forward walkthrough in [`k8s/README.md`](k8s/README.md).

---

## Use

The OpenAI-compatible API listens on port `8000`.

### Path A — docker-compose

```bash
curl -s http://127.0.0.1:8000/v1/models | jq
```

Default binding is `127.0.0.1` only.\
Drop the localhost prefix in `docker-compose.yml` and add `--api-key` to expose on LAN.

### Path B — k3s

External LAN access via the MetalLB-assigned VIP:
```bash
curl -s http://192.168.1.251:8000/v1/models | jq
```

In-cluster:
```bash
curl -s http://vllm.vllm.svc.cluster.local:8000/v1/models | jq
```

Port-forward (no LAN routing needed):
```bash
kubectl -n vllm port-forward svc/vllm 8000:8000
curl -s http://127.0.0.1:8000/v1/models | jq
```

---

## Test

End-to-end inference with the configured model:
```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "qwen3-coder-30b-a3b",
      "messages": [{"role": "user", "content": "Say HELLO once."}],
      "max_tokens": 16,
      "temperature": 0
    }' | jq -r '.choices[0].message.content'
```

Tool-call smoke (uses the parser configured in `--tool-call-parser`):
```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "qwen3-coder-30b-a3b",
      "messages": [{"role": "user", "content": "What is the weather in Tokyo?"}],
      "tools": [{"type": "function", "function": {"name": "get_weather", "parameters": {"type": "object", "properties": {"location": {"type": "string"}}}}}],
      "tool_choice": "auto"
    }' | jq '.choices[0].message.tool_calls'
```

Bandwidth + capability tests for the GPU itself live in [`apnex/nvidia-driver-injector`'s `diag/`](https://github.com/apnex/nvidia-driver-injector/tree/main/diag) — orthogonal to vLLM.

---

## Remove

### Path A — docker-compose

```bash
docker compose down
```

Weights stay in `/root/.cache/huggingface` across recreates.

### Path B — k3s

```bash
kubectl delete -f k8s/
```

Namespace + workload + configmap + service all go.\
Weights stay in `/root/.cache/huggingface` on the host.

---

## Architecture

```
Layer 4  Client                       - OpenCode / aider / curl
Layer 3  Workload                     - vLLM (this repo)
Layer 2  Driver injector container    - apnex/nvidia-driver-injector
Layer 1  Host config                  - cmdline / modprobe.d / udev / bridge cap
Layer 0  Hardware                     - AORUS 5090 over TB, NUC 15 Pro+
```

`Layer 0`-`Layer 1`-`Layer 2` are out of scope for this repo.

- Owned by [`apnex/nvidia-driver-injector`](https://github.com/apnex/nvidia-driver-injector).

`Layer 3` is the workload at this repo's root.

- Consumes `/dev/nvidia*` via the `nvidia` runtime class.
- Serves OpenAI-compatible HTTP on port `8000`.
- Loads HF weights from `/root/.cache/huggingface` (bind-mounted).

`Layer 4` is the client.

- Any OpenAI-compatible client (OpenCode, aider, raw `curl`).

---

## Troubleshooting

### Pod stuck `Pending` with `0/1 nodes are available`

The producer's node label `nvidia.driver/state=ready` is absent.\
The driver injector either has not finished rolling out or has failed.

Verify the producer:
```bash
kubectl get nodes -L nvidia.driver/state,nvidia.driver/version
kubectl -n kube-system rollout status ds/nvidia-driver-injector
```

### `RuntimeClass "nvidia" not found`

The host's containerd was not configured with the `nvidia` runtime.\
Run the driver injector's `apply.sh` — it calls `nvidia-ctk runtime configure --runtime=containerd` and creates the `RuntimeClass`.

### Cold start exceeds the startup probe window

First start downloads weights (~17 GB for the default model) at `HF_HUB_ENABLE_HF_TRANSFER=1` rate.\
The startup probe allows 1800s.\
If the model is larger or the HF mirror is slow, raise `startupProbe.failureThreshold` in [`k8s/deployment.yaml`](k8s/deployment.yaml).

### Container exits with `CUDA out of memory` at load

The model + KV cache exceeds the GPU.\
Lower `VLLM_MAX_MODEL_LEN` in [`k8s/configmap.yaml`](k8s/configmap.yaml) or `VLLM_GPU_MEM_UTIL`.\
The default `98304` context + `0.92` utilisation is sized for the 30B-A3B-AWQ on a 32 GiB 5090.

### Tool calls return malformed JSON

The `--tool-call-parser` value must match the model family.\
Mapping:

| Model family | Parser |
|---|---|
| Llama 3.x | `llama3_json` |
| Llama 4.x | `llama4_pythonic` |
| Mistral | `mistral` |
| Hermes | `hermes` |
| Gemma 4 | `gemma4` |
| Qwen 3 | `qwen3_xml` |
| Qwen 3 Coder | `qwen3_coder` |

Override via `VLLM_TOOL_PARSER` in [`k8s/configmap.yaml`](k8s/configmap.yaml) (Path B) or `.env` (Path A).

---

## Version pin rationale

Pinned to `vllm/vllm-openai:v0.20.2` (R11 production-validated).

v0.21.0 is intentionally skipped.\
The audit at [`audit/v0.21.0/CONSOLIDATED.md`](audit/v0.21.0/CONSOLIDATED.md) found:

- `v0.21.1rc0` already tagged with 169 commits + 12 cherry-picks fixing post-release bugs.
- Two of those cherry-picks (`#42292` Qwen3CoderTool, `#42434` Core routing-replay revert) directly hit our path.
- Confirmed RTX 5090 startup hang (`#42987`) and sustained-traffic engine hang (`#42897`) reproduce on stock `v0.21.0`.

The roll-forward target is `v0.21.1` final.

---

## Why this exists

vLLM is the inference engine.\
This repo is the deployment surface — compose for dev, k3s for prod — that turns the engine into a service consuming the patched GPU stack.\
The hard problems (Thunderbolt-attached Blackwell hard-locks, PCIe transients, GSP firmware bringup) live in the driver injector below.\
This layer is intentionally thin.

---

## License

MIT.

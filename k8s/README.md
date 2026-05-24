# k8s/

Raw k3s manifests for the vLLM OpenAI-compatible inference server.

## Files

| File | Purpose |
|---|---|
| `namespace.yaml` | `vllm` namespace |
| `configmap.yaml` | Model identity + engine args (override per deployment) |
| `deployment.yaml` | Single-replica vLLM workload pinned to `vllm/vllm-openai:v0.20.2` |
| `service.yaml` | `ClusterIP` service exposing port 8000 (in-cluster) |
| `vip-service.yaml` | `LoadBalancer` service `vip-vllm` (external VIP via MetalLB) |
| `metallb.yaml` | `IPAddressPool vllm-pool` + `L2Advertisement vllm-l2` |

## Apply

```bash
kubectl apply -f k8s/
```

Order is namespace → configmap → deployment → service.\
Modern `kubectl` handles the namespace dependency automatically.

## Verify

```bash
kubectl -n vllm get pods -w
kubectl -n vllm rollout status deployment/vllm
```

First start is slow: HF download + torch.compile + CUDA graphs typically takes 5-15 min cold.\
The startup probe has a 1800s window for this.

## Reach the server

Three paths are exposed, pick whichever matches your client location:

In-cluster (other pods in this k3s):
```bash
curl http://vllm.vllm.svc.cluster.local:8000/v1/models | jq
```

External LAN (any host on the network):
```bash
curl http://192.168.1.251:8000/v1/models | jq
```

Localhost-only via port-forward (useful from the host before LAN routing is set up):
```bash
kubectl -n vllm port-forward svc/vllm 8000:8000
curl http://127.0.0.1:8000/v1/models | jq
```

The LAN VIP `192.168.1.251` is provisioned by MetalLB from `vllm-pool` and is dedicated to `vip-vllm`.\
Other cluster services share `192.168.1.250` via `host-pool` — pool separation prevents port collisions.

## Producer / consumer contract

The deployment gates on labels published by [`apnex/nvidia-driver-injector`](https://github.com/apnex/nvidia-driver-injector):

- `nodeSelector: nvidia.driver/state=ready`
- `runtimeClassName: nvidia`
- `env: NVIDIA_VISIBLE_DEVICES=all`

If the driver injector has not finished rolling out, the pod will sit `Pending` with `0/1 nodes are available`.\
Verify the producer first:

```bash
kubectl get nodes -L nvidia.driver/state,nvidia.driver/version
```

## Change the model

Edit `configmap.yaml` and re-apply:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl -n vllm rollout restart deployment/vllm
```

The `tool-call-parser` value must match the model family (`qwen3_coder`, `qwen3_xml`, `llama3_json`, `gemma4`, `mistral`, `hermes`, ...).\
See vLLM's `tool_parsers/` directory for the full list.

## Version pin rationale

`vllm/vllm-openai:v0.20.2` is the R11-validated production version (locked 2026-05-10).\
v0.21.0 is intentionally skipped — see [`audit/v0.21.0/CONSOLIDATED.md`](../audit/v0.21.0/CONSOLIDATED.md) for the audit and `v0.21.1` rollout plan.

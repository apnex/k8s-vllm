# Soak monitoring

Lightweight host-side observability for the 14-day vLLM v0.20.2 soak.\
Two systemd timers scrape vLLM and snapshot k8s state to `/var/log/vllm-soak/`.

## Install

Run from the repo root as root:
```bash
sudo ./tools/soak-install.sh
```

The install script copies the two shell scripts to `/usr/local/sbin/vllm-soak-{metrics,pods}.sh` and the four unit files to `/etc/systemd/system/`.\
Scripts go to `/usr/local/sbin/` (not executed in place from `/root/k8s-vllm/tools/`) because Fedora's SELinux policy denies `init_t` (systemd) execution of `admin_home_t`-labeled files under `/root/`.\
`/usr/local/sbin/` is labeled `bin_t` which `init_t` can execute.

Sets up:

| Unit | Triggers | Captures |
|---|---|---|
| `vllm-soak-metrics.timer` | every 30s | one CSV row of vLLM `/metrics` counters |
| `vllm-soak-pods.timer` | daily 00:30 UTC | pod state + restart counts + recent events + `/health` probe |

Output dir: `/var/log/vllm-soak/`.

## What gets captured

### `metrics.csv` (one row every 30s)

```
ts_iso,generation_tokens_total,prompt_tokens_total,num_requests_running,num_requests_waiting,prefix_cache_queries_total,prefix_cache_hits_total,scrape_ok
2026-05-24T11:30:00Z,12345,67890,2,0,3456,2789,1
```

Columns:

- `ts_iso` — UTC ISO 8601
- `generation_tokens_total` — monotonic counter; **the wedge sentinel**
- `prompt_tokens_total` — monotonic; cross-check workload presence
- `num_requests_running` — in-flight requests
- `num_requests_waiting` — queue depth
- `prefix_cache_queries_total` + `prefix_cache_hits_total` — for hit-rate analysis
- `scrape_ok` — `1` if `/metrics` returned, `0` if curl failed (visible gap)

### `pods-YYYYMMDD.txt` (one file per day)

Plain-text snapshot:

- `kubectl get pods -n vllm -o wide`
- deployment status + container restart counts
- last 50 events sorted by time
- `/health` probe result (http_code + time_total)
- `/v1/models` response (first 20 lines)

## Inspect during soak

Live metrics tail:
```bash
tail -f /var/log/vllm-soak/metrics.csv | column -t -s,
```

Today's pod state:
```bash
cat /var/log/vllm-soak/pods-$(date -u +%Y%m%d).txt
```

Day-over-day pod diff:
```bash
diff /var/log/vllm-soak/pods-$(date -u -d yesterday +%Y%m%d).txt \
     /var/log/vllm-soak/pods-$(date -u +%Y%m%d).txt
```

Timer health:
```bash
systemctl list-timers 'vllm-soak-*' --no-pager
journalctl -u vllm-soak-metrics.service --since '1 hour ago' --no-pager
```

## Wedge detection

The `#42897` failure mode (audit ref) signature in `metrics.csv`:

- `num_requests_running > 0` for ≥3 consecutive rows (90s window)
- AND `generation_tokens_total` unchanged across the same rows

Quick check across the last hour:
```bash
tail -n 120 /var/log/vllm-soak/metrics.csv \
  | awk -F, 'NR>1 && $4>0 {if ($2==prev) c++; else c=0; prev=$2; if (c>=3) print "WEDGE candidate at " $1}'
```

Healthy idle (no traffic) is correctly ignored — the `num_requests_running > 0` gate keeps the detector quiet when nothing's in flight.

## Limits + non-goals

- **No alerting.** Eyeballing during soak is the right effort level. If a wedge fires post-soak, the watchdog livenessProbe is the next layer (Phase 2 — see project plan).
- **No log content capture.** vLLM stdout is not tailed to a file. Use `kubectl logs -n vllm deployment/vllm --since=1h` on demand.
- **No metrics aggregation.** No Prometheus/Loki — single CSV file is sufficient for one-pod soak.
- **Output dir is host-local.** `/var/log/vllm-soak/` survives pod restarts but not host reinstalls. Copy off if you want it preserved past soak teardown.

## Uninstall

```bash
sudo ./tools/soak-uninstall.sh
```

Stops + disables the timers, removes unit files, leaves `/var/log/vllm-soak/` intact for post-soak inspection.

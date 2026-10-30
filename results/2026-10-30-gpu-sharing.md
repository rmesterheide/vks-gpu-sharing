# GPU sharing with DRA on VKS, measured 2026-10-30 22:33 to 22:45

One RTX A5000 (passthrough into one VKS worker), cluster `gpu-dra` on VKr 1.36.4, GPU Operator 26.7.2 in GPUCluster mode
with the managed DRA driver 0.5.1 (driver 595.91.07, CUDA 13.2), feature gates TimeSlicingSettings and MPSSupport.
Workload: llama.cpp `server-cuda-b11913`, Gemma 4 12B QAT q4_0 (6.98 GB GGUF from Harbor), `--n-gpu-layers 99
--ctx-size 16384 --flash-attn on --reasoning-budget 0 --jinja`, 4 slots per instance. Load from the MacBook through
`kubectl port-forward`, straight to llama-server (no PAIS gateway): `dra-bench.py`, essay prompt, 400 tokens per answer,
one streaming request, one and four parallel non-streaming requests. Raw output: `results/raw/` (control run and sharing runs,
port-forward noise removed).

## Tokens per second

| Setup | single stream (after first token) | 1 request | 4 parallel, aggregate (per request) | both busy, 1 each (per instance / sum) | both busy, 4 each (per instance / sum) |
|---|---|---|---|---|---|
| One instance, whole card through a DRA claim (control, 22:34) | 75.9 | 72.0 | 201.6 (50.4) | | |
| Two instances, TimeSlicing interval Default (22:40) | 75.2 / 74.7 | 72.2 / 71.8 | 202.9 / 198.5 | 29.8 / 59.6 | 96.0 / 192.0 |
| Two instances, TimeSlicing interval Long (22:42) | 74.4 / 74.0 | 71.4 / 71.3 | 198.2 / 195.0 | 29.6 / 59.2 | 95.1 / 190.1 |
| Two instances, MPS 50 % threads, 10 Gi pinned each (22:44) | 57.8 / 57.4 | 55.0 / 55.0 | 139.3 / 138.0 | 36.1 / 72.1 | 106.1 / 212.2 |

TTFT direct to llama-server: 0.12 to 0.21 s in every setup (the 1.1 s of part 3 was the gateway path).
Part 3 reference through the PAIS gateway with the device plugin: 70.9 single, 242.7 at 4 parallel (different path,
not directly comparable at 4 parallel; the single-request numbers match).

## Reading

- DRA itself costs nothing: 72.0 / 201.6 through a claim against 72.6 single in part 3.
- Time-slicing is free while the neighbour is idle (72 and 200 with the second instance loaded but quiet), splits
  exactly in half under load, and loses about 5 % of the card at 4+4 (192 of 201.6). With one request per instance
  the context switches cost about a sixth: 59.6 together instead of 72 for one instance alone.
- The `Long` interval changed nothing measurable for this workload (differences under 2 %).
- MPS caps a lone tenant at about three quarters (55 of 72, 139 of 202) because of the 50 % thread share, but under
  load from both it delivers more than one instance alone (212 vs 202) and better latency per tenant when both are
  busy with single requests (36 vs 30 tok/s each). The control daemon appeared with the claim and ended with it; the
  card switched to EXCLUSIVE_PROCESS for the duration.
- Model load from the PVC: about 3 s per instance in every run.

## Not measured

Memory isolation (both time-slicing tenants see 24 GB; the MPS pinned limit of 10 Gi was not pushed), eight
parallel per instance, mixed models, vGPU (planned, same table).

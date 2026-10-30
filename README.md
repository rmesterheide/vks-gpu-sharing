# vks-gpu-sharing

Scripts and manifests to reproduce GPU sharing with Dynamic Resource Allocation (DRA) on vSphere Kubernetes Service (VKS). The lab uses one NVIDIA RTX A5000 in passthrough and two llama.cpp servers on that one card. Sharing is done with time-slicing and Multi-Process Service (MPS). A single-tenant run is the baseline.

This is the companion to the blog post "Sharing one GPU on the Kubernetes layer" on raimes.ai. The scripts are the ones used in the lab run of 2026-10-30. They are lab scripts, not a product. Read them before you run them.

## What you need

- vSphere 9.1 with a Supervisor.
- VKS with a VKr 1.34.2 or newer. The lab used 1.36.4.
- A VM class with the GPU in DirectPath passthrough (the lab class is called `a5000-passthrough`).
- A storage class. The scripts and the manifest name the lab's class `k8s-990pro`; replace it with yours.
- Helm 3.8 or newer, and kubectl with the vSphere plugin.
- A GGUF model. The lab pulled Gemma 4 12B QAT from a private Harbor registry with oras 1.3.0 (the artifact from `vcf pais models push`, Private AI Services (PAIS), pulls as plain files). Any OCI registry or a plain download works. The pod only needs a `.gguf` on the PVC.

## Lab setup

- Supervisor on vSphere 9.1.1. Cluster from the ClusterClass `builtin-generic-v3.7.0`, VKr 1.36.4 (Kubernetes 1.36.4, Ubuntu 24.04.5 nodes, containerd 2.3.4). Container Device Interface (CDI) is on by default. The cluster was Available 8 minutes after apply.
- GPU Operator v26.7.2 via Helm in GPUCluster mode: `clusterPolicy.deployCR=false`, `gpuCluster.deployCR=true`, `driver.nvidiaDriverCRD.enabled=true`, `devicePlugin.enabled=false`, `draDriver.computeDomains.enabled=false`, and the `draDriver.featureGates` `TimeSlicingSettings` and `MPSSupport` set to true.
- Operator-managed DRA driver v0.5.1. Driver 595.91, built on the node in about 3 minutes.
- DeviceClasses `gpu.nvidia.com`, `mig.nvidia.com`, `vfio.gpu.nvidia.com`. One ResourceSlice with the device `gpu-0`. This driver version publishes no memory attribute.

## Run order

Set these first:

- `SUPERVISOR_NS`: your Supervisor namespace (default `pais`).
- `HARBOR`: your registry host and port, used by the model pull (`dra-share.sh` sets `ART` to `$HARBOR/models/google/gemma-4-12b-qat-gguf:v1`; change `ART` for another model).
- Kubeconfig: `dra-cluster-create.sh` writes `/tmp/gpu-dra.kubeconfig`. The other scripts read it.

The scripts expect to sit in `~/`. Copy them there, and log in with `kubectl vsphere login --instance <supervisor> -u <user> --insecure-skip-tls-verify`.

1. Check the Supervisor and the DRA API (read-only):
   `zsh ~/dra-check.sh 2>&1 | tee /tmp/dra-check.txt`
2. Create the cluster. Edit the manifest inside `dra-cluster-create.sh` first (namespace, VM classes, storage class, CA; `manifests/cluster-gpu-dra.yaml` is the same manifest as a plain file):
   `MODE=create zsh ~/dra-cluster-create.sh 2>&1 | tee /tmp/dra-cluster-create.txt`
   `MODE=free` and `MODE=all` are lab specific: they first delete a Private AI Services (PAIS) model endpoint that held the card. Skip them unless you have the same setup.
   Later status check: `MODE=status zsh ~/dra-cluster-create.sh`
3. Install the GPU Operator and the DRA driver. The script labels the namespaces for Pod Security Admission (see Traps):
   `MODE=install zsh ~/dra-install.sh 2>&1 | tee /tmp/dra-install.txt`
   Then `MODE=status zsh ~/dra-install.sh`.
4. Prepare the model: namespace, pull secret, PVC and the pull Job:
   `HARBOR=<registry/project> MODE=prep zsh ~/dra-share.sh 2>&1 | tee /tmp/dra-share-prep.txt`
5. Claim test with one pod and the whole GPU:
   `MODE=claim zsh ~/dra-install.sh 2>&1 | tee /tmp/dra-claim.txt`
6. Share runs. Each one starts the pod `share`:
   - `MODE=ts zsh ~/dra-share.sh` (time-slicing, `TS_INTERVAL=Default|Short|Medium|Long`)
   - `MODE=mps zsh ~/dra-share.sh`
   - `MODE=solo zsh ~/dra-share.sh` (one container, the control run)
7. Bench after each run: `MODE=bench zsh ~/dra-share.sh`. It port-forwards and calls `dra-bench.py`. You can also run it by hand: `PAR=4 TOK=400 python3 ~/dra-bench.py 8080 8081`.
8. Clean up: `MODE=clean zsh ~/dra-share.sh`.

`dra-run5.sh` chains steps 5 to 8 in one run (`zsh ~/dra-run5.sh 2>&1 | tee /tmp/dra-run5.txt`). It needs `dra-install.sh`, `dra-share.sh` and `dra-bench.py` in `~/`.

## Scripts

- `dra-check.sh`: read-only checks of the DRA API, runtime version and Supervisor resources.
- `dra-cluster-info.sh`: read-only. Reads the values a new cluster needs (class, storage, VM classes, images).
- `dra-cluster-create.sh`: frees the card, creates the cluster, reports status.
- `dra-install.sh`: GPU Operator install, Pod Security labels, status, whole-GPU claim test.
- `dra-share.sh`: model prep and the share, solo, status, bench and clean modes.
- `dra-bench.py`: sends one streaming request (time to first token, tokens per second), then parallel requests. With two ports it loads both instances at once.
- `dra-run5.sh`: the full measurement chain.
- `dra-debug.sh`, `dra-nudge.sh`: read-only diagnosis and a retry nudge, written while fixing trap 1.

## Manifests

- `cluster-gpu-dra.yaml`: the VKS cluster with a passthrough worker, an 80Gi containerd volume and `maxSurge: 0`.
- `claim-whole-gpu.yaml`: a ResourceClaimTemplate and a pod that runs `nvidia-smi`.
- `claim-timeslicing.yaml`: ResourceClaimTemplate with the TimeSlicing strategy.
- `claim-mps.yaml`: ResourceClaimTemplate with the MPS strategy (50 percent thread limit, 10Gi pinned memory limit).
- `pod-two-llama-servers.yaml`: one pod, two llama.cpp containers on ports 8080 and 8081, both bound to the same claim request.

## Traps

1. Pod Security Admission. VKS enforces `restricted:latest` on new namespaces. The controllers reject GPU Operator pods without a visible error. Look for `FailedCreate ... violates PodSecurity` in events. Fix: label the namespace `pod-security.kubernetes.io/enforce=privileged` (and `warn`, `audit`), then `rollout restart`.
2. Node disk. The default disk is too small for GPU images (pod evicted: low on ephemeral-storage). Fix: a `volumes` override on the worker machine deployment with a dedicated containerd volume of 80Gi. Set rollout `maxSurge: 0` and `maxUnavailable: 1`, so the single passthrough card can move to the replacement VM.
3. A ResourceClaimTemplate spec is immutable. Delete and recreate it when you switch strategy.

## Results

Measured 2026-10-30 on one RTX A5000, Gemma 4 12B QAT on llama.cpp, 400 tokens per answer, four parallel requests per instance; full table and reading in `results/2026-10-30-gpu-sharing.md`, raw runs in `results/raw/`.

| Setup | 1 request tok/s | 4 parallel per instance | card total |
|---|---|---|---|
| One instance, whole card through a DRA claim | 72.0 | 201.6 | 201.6 |
| Two instances, time-slicing, one busy | 72.2 | 202.9 | 202.9 |
| Two instances, time-slicing, both busy | 29.8 + 29.8 | 96.0 + 96.0 | 192.0 |
| Two instances, MPS 50/50, both busy | 36.1 + 36.1 | 106.1 + 106.1 | 212.2 |

Time-slicing is free while the neighbour is idle and splits the card in half under load (about 5 % lost in total). MPS caps a lone tenant at about three quarters and delivers more than one instance alone when both are busy. The time-slice interval (`Default` vs `Long`) made no measurable difference.

## Scope and limits

- One host, one card, one node.
- Time-slicing and MPS only.
- No MIG: the A5000 does not support it.
- No ComputeDomains.
- A comparison with vGPU is planned.

## License

Apache 2.0. See `LICENSE`.

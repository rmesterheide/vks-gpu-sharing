#!/bin/zsh
# DRA plan B, step 6 and test 3/4 (2026-10-30): GPU Operator 26.7.2 with the operator-managed DRA driver on the
# VKS cluster gpu-dra, then the first ResourceClaim.
#  install : wait for both nodes Ready, helm repo nvidia, GPU Operator v26.7.2 in GPUCluster mode
#            (clusterPolicy.deployCR=false, gpuCluster.deployCR=true, NVIDIADriver CRD, no ComputeDomains, device plugin off,
#            feature gates TimeSlicingSettings and MPSSupport on), then watch up to 12 minutes
#  psa     : label gpu-operator and dra-test privileged (fix for the 21:31 run), then watch and status
#  status  : GPUCluster, operator pods, DeviceClasses, ResourceSlices (attributes to /tmp/gpu-dra-resourceslices.yaml)
#  claim   : test 4, one pod with a whole-GPU ResourceClaimTemplate, nvidia-smi inside (namespace dra-test)
# Run on the MacBook (kubeconfig from dra-cluster-create.sh MODE=status, needs helm):
#   MODE=install zsh ~/dra-install.sh 2>&1 | tee /tmp/dra-install.txt
#   MODE=status  zsh ~/dra-install.sh 2>&1 | tee /tmp/dra-status.txt
#   MODE=claim   zsh ~/dra-install.sh 2>&1 | tee /tmp/dra-claim.txt
set -u
MODE=${MODE:-status}
KC=/tmp/gpu-dra.kubeconfig
OPV=${OPV:-v26.7.2}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
k() { kubectl --kubeconfig $KC "$@"; }
[[ -f $KC ]] || { print -r -- "$KC missing: run MODE=status zsh ~/dra-cluster-create.sh first"; exit 1; }

watch_operator() {
  h "watch up to 12 minutes (driver build on Ubuntu 24.04 took about 3 min on the PAIS cluster)"
  for i in {1..36}; do
    sleep 20
    G=$(k get gpucluster gpu-cluster -o jsonpath='{.status.state}' 2>/dev/null)
    N=$(k -n gpu-operator get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
    P=$(k -n gpu-operator get pods --no-headers 2>/dev/null | grep -v -E ' Running | Completed ' | awk '{print $1":"$3}' | tr '\n' ' ')
    S=$(k get resourceslices --no-headers 2>/dev/null | wc -l | tr -d ' ')
    print -r -- "  $(date +%T) gpucluster=${G:--} pods=$N slices=$S notready: ${P:-none}"
    [[ $G == ready && $S -ge 1 ]] && break
  done
}

status() {
  h "status"
  k get nodes -o wide 2>&1 | sed 's/^/  /'
  k get gpucluster 2>&1 | sed 's/^/  gpucluster: /'
  k get gpucluster gpu-cluster -o jsonpath='{range .status.conditions[*]}{"  cond: "}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null
  k get nvidiadrivers -o wide 2>/dev/null | sed 's/^/  driver cr: /'
  k -n gpu-operator get pods --no-headers 2>/dev/null | awk '{print "  pod:", $1, $2, $3}'
  k get deviceclasses 2>&1 | sed 's/^/  /'
  k get resourceslices -o custom-columns='SLICE:.metadata.name,DRIVER:.spec.driver,NODE:.spec.nodeName,DEVICES:.spec.devices[*].name' --no-headers 2>/dev/null | sed 's/^/  slice: /'
  k get resourceslices -o yaml > /tmp/gpu-dra-resourceslices.yaml 2>/dev/null && print -r -- "  resourceslices saved to /tmp/gpu-dra-resourceslices.yaml ($(wc -l < /tmp/gpu-dra-resourceslices.yaml) lines)"
  k get resourceslices -o jsonpath='{range .items[*].spec.devices[*]}{.name}{": "}{.attributes}{"\n"}{end}' 2>/dev/null | cut -c1-900 | sed 's/^/  attrs: /'
}

if [[ $MODE == install ]]; then
  command -v helm >/dev/null || { print -r -- "helm missing on the MacBook: brew install helm"; exit 1; }
  h "1. wait for nodes Ready (up to 20 min)"
  for i in {1..60}; do
    R=$(k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    print -r -- "  $(date +%T) nodes Ready: $R"
    [[ $R -ge 2 ]] && break
    sleep 20
  done
  k get nodes -o wide 2>&1 | sed 's/^/  /'
  k get clusterpolicy 2>&1 | head -2 | sed 's/^/  clusterpolicy check: /'
  h "2. helm repo nvidia"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1; helm repo update nvidia 2>&1 | tail -1
  helm search repo nvidia/gpu-operator --versions 2>/dev/null | head -4
  h "3. install GPU Operator $OPV in GPUCluster mode with the managed DRA driver"
  k create ns gpu-operator --dry-run=client -o yaml | k apply -f - >/dev/null
  k label ns gpu-operator pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged --overwrite
  helm --kubeconfig $KC upgrade --install gpu-operator nvidia/gpu-operator --version=$OPV \
    --namespace gpu-operator --create-namespace \
    --set clusterPolicy.deployCR=false --set gpuCluster.deployCR=true \
    --set driver.nvidiaDriverCRD.enabled=true \
    --set devicePlugin.enabled=false \
    --set draDriver.computeDomains.enabled=false \
    --set draDriver.featureGates.TimeSlicingSettings=true \
    --set draDriver.featureGates.MPSSupport=true 2>&1 | tail -12
  watch_operator
  status
  k -n gpu-operator get gpucluster gpu-cluster -o jsonpath='{.spec.draDriver}' 2>/dev/null | cut -c1-600 | sed 's/^/  draDriver spec: /'; print
fi

if [[ $MODE == psa ]]; then
  h "pod security: namespaces gpu-operator and dra-test to privileged (VKS default for new namespaces is restricted)"
  k get ns gpu-operator dra-test --show-labels 2>&1 | sed 's/^/  before: /'
  for n in gpu-operator dra-test; do
    k label ns $n pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged --overwrite
  done
  watch_operator
  status
  h "model-pull job after the label"
  k -n dra-test get job,pod 2>&1 | sed 's/^/  /'
  k -n dra-test logs job/model-pull --tail=12 2>&1 | sed 's/^/  /'
fi

if [[ $MODE == claim ]]; then
  h "test 4: one pod, whole GPU through a ResourceClaimTemplate"
  k create ns dra-test --dry-run=client -o yaml | k apply -f - >/dev/null
  cat <<'YAML' | k apply -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: single-gpu
  namespace: dra-test
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
---
apiVersion: v1
kind: Pod
metadata:
  name: smi
  namespace: dra-test
spec:
  restartPolicy: Never
  containers:
  - name: smi
    image: nvcr.io/nvidia/cuda:13.0.1-base-ubuntu24.04
    command: ["sh", "-c", "nvidia-smi; nvidia-smi --query-gpu=name,driver_version,memory.total,compute_mode --format=csv; env | grep -i -E 'nvidia|cuda' | sort"]
    resources:
      claims:
      - name: gpu
        request: gpu
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: single-gpu
YAML
  for i in {1..30}; do
    PH=$(k -n dra-test get pod smi -o jsonpath='{.status.phase}' 2>/dev/null)
    print -r -- "  $(date +%T) pod smi: $PH"
    [[ $PH == Succeeded || $PH == Failed ]] && break
    sleep 10
  done
  k -n dra-test get resourceclaims -o custom-columns='CLAIM:.metadata.name,STATE:.status.allocation.devices.results[*].device,DRIVER:.status.allocation.devices.results[*].driver' 2>/dev/null | sed 's/^/  /'
  k -n dra-test describe pod smi 2>/dev/null | grep -A8 '^Events' | sed 's/^/  /'
  print -r -- "--- nvidia-smi output"
  k -n dra-test logs smi 2>&1 | sed 's/^/  /'
  k -n dra-test delete pod smi --ignore-not-found >/dev/null
fi

[[ $MODE == status ]] && status
print -r -- ""
print -r -- "done $(date +%T)"

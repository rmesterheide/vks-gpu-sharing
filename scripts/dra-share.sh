#!/bin/zsh
# DRA plan B, tests 5 and 6 (2026-10-30): two llama-server containers share the A5000 through one ResourceClaim.
#  prep  : namespace dra-test, Harbor pull secret copied from the Supervisor namespace pais, VIS CA ConfigMap,
#          PVC models (30Gi k8s-990pro), Job model-pull (oras pulls google/gemma-4-12b-qat-gguf:v1 from Harbor)
#  ts    : ResourceClaimTemplate shared-gpu with sharing.strategy TimeSlicing (TS_INTERVAL=Default|Short|Medium|Long)
#          and pod share with containers llama-a (8080) and llama-b (8081), same args as the PAIS endpoint
#  mps   : same pod, strategy MPS (defaultActiveThreadPercentage 50, defaultPinnedDeviceMemoryLimit 10Gi)
#  solo  : same template as ts but only llama-a (control run)
#  status: claims, pod, GPU processes as seen by nvidia-smi in the driver pod
#  bench : port-forward to the containers and run ~/dra-bench.py (solo and concurrent runs)
#  clean : delete pod share and the claim template (keeps PVC and model)
# Run on the MacBook (needs /tmp/gpu-dra.kubeconfig and a Supervisor login for prep):
#   MODE=prep zsh ~/dra-share.sh 2>&1 | tee /tmp/dra-share-prep.txt
#   MODE=ts   zsh ~/dra-share.sh 2>&1 | tee /tmp/dra-share-ts.txt
set -u
MODE=${MODE:-status}
KC=/tmp/gpu-dra.kubeconfig
NS=dra-test; SNS=${SUPERVISOR_NS:-pais}
TS_INTERVAL=${TS_INTERVAL:-Default}
ART=${HARBOR}/models/google/gemma-4-12b-qat-gguf:v1
IMG=${IMG:-ghcr.io/ggml-org/llama.cpp:server-cuda-b11913}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
k() { kubectl --kubeconfig $KC "$@"; }
[[ -f $KC ]] || { print -r -- "$KC missing: run MODE=status zsh ~/dra-cluster-create.sh first"; exit 1; }

llama_container() { # name port
  cat <<YAML
  - name: $1
    image: $IMG
    command: ["sh", "-c", "exec /app/llama-server --model \$(ls /models/*.gguf | head -1) --host 0.0.0.0 --port $2 --n-gpu-layers 99 --ctx-size 16384 --flash-attn on --reasoning-budget 0 --jinja --metrics"]
    ports: [{containerPort: $2}]
    volumeMounts: [{name: models, mountPath: /models, readOnly: true}]
    resources:
      claims: [{name: gpu, request: gpu}]
    readinessProbe: {httpGet: {path: /health, port: $2}, initialDelaySeconds: 10, periodSeconds: 5}
YAML
}

share_pod() { # strategy-yaml containers(a|ab)
  cat <<YAML
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata: {name: shared-gpu, namespace: $NS}
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly: {deviceClassName: gpu.nvidia.com}
      config:
      - requests: ["gpu"]
        opaque:
          driver: gpu.nvidia.com
          parameters:
            apiVersion: resource.nvidia.com/v1beta1
            kind: GpuConfig
            sharing:
$1
---
apiVersion: v1
kind: Pod
metadata: {name: share, namespace: $NS, labels: {app: share}}
spec:
  restartPolicy: Never
  volumes:
  - name: models
    persistentVolumeClaim: {claimName: models}
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: shared-gpu
  containers:
$(llama_container llama-a 8080)
$( [[ $2 == ab ]] && llama_container llama-b 8081 )
YAML
}

wait_pod() {
  for i in {1..60}; do
    R=$(k -n $NS get pod share -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready} {end}' 2>/dev/null)
    PH=$(k -n $NS get pod share -o jsonpath='{.status.phase}' 2>/dev/null)
    print -r -- "  $(date +%T) $PH $R"
    [[ $R == *"false"* || -z $R ]] || break
    [[ $PH == Failed ]] && break
    k -n $NS get pod share -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}' 2>/dev/null | grep -q -E 'ErrImagePull|ImagePullBackOff|CreateContainerError' && { print -r -- "  image or container error, stopping the wait"; break; }
    sleep 10
  done
  k -n $NS describe pod share 2>/dev/null | grep -A10 '^Events' | tail -10 | sed 's/^/  /'
}

status() {
  h "status"
  k -n $NS get pvc,job,pod -o wide 2>&1 | sed 's/^/  /'
  k -n $NS get resourceclaims -o custom-columns='CLAIM:.metadata.name,DEVICE:.status.allocation.devices.results[*].device,POOL:.status.allocation.devices.results[*].pool,RESERVED:.status.reservedFor[*].name' --no-headers 2>/dev/null | sed 's/^/  claim: /'
  DP=$(k -n gpu-operator get pods --no-headers 2>/dev/null | grep -E 'nvidia-gpu-driver|nvidia-driver-daemonset' | awk '{print $1}' | head -1)
  [[ -n $DP ]] && k -n gpu-operator exec $DP -c nvidia-gpu-driver-ctr -- nvidia-smi --query-gpu=name,compute_mode,memory.used,utilization.gpu --format=csv 2>/dev/null | sed 's/^/  gpu: /'
  [[ -n $DP ]] && k -n gpu-operator exec $DP -c nvidia-gpu-driver-ctr -- nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null | sed 's/^/  proc: /'
  MC=$(k -n gpu-operator get deploy --no-headers 2>/dev/null | grep mps-control-daemon | awk '{print $1}')
  [[ -n $MC ]] && print -r -- "  mps control daemon: $MC"
  for c in llama-a llama-b; do k -n $NS logs share -c $c --tail=3 2>/dev/null | cut -c1-160 | sed "s/^/  $c: /"; done
}

case $MODE in
prep)
  h "1. namespace, Harbor pull secret from Supervisor namespace $SNS, VIS CA"
  kubectl config use-context $SNS >/dev/null 2>&1 || { print -r -- "Supervisor login missing (kubectl vsphere login ...)"; exit 1; }
  PULL=$(kubectl -n $SNS get secret -o name | grep '^secret/pais-pais-reg-creds-' | head -1 | cut -d/ -f2)
  [[ -n $PULL ]] || { print -r -- "no pais-pais-reg-creds-* secret in $SNS"; exit 1; }
  k create ns $NS --dry-run=client -o yaml | k apply -f - >/dev/null
  k label ns $NS pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null
  kubectl -n $SNS get secret $PULL -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/.dra-dockercfg.json
  k -n $NS create secret generic harbor-creds --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/tmp/.dra-dockercfg.json --dry-run=client -o yaml | k apply -f - >/dev/null
  rm -f /tmp/.dra-dockercfg.json
  print -r -- "  secret harbor-creds created from $PULL (registries: $(k -n $NS get secret harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["auths"].keys()))'))"
  cat <<'YAML' | k -n $NS apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata: {name: vis-ca}
data:
  ca.pem: |
    <registry root CA PEM, indented like this line; see manifests/cluster-gpu-dra.yaml>
YAML
  print -r -- "  configmap vis-ca created"
  k api-resources 2>/dev/null | grep -i -E 'nvidia|resource.k8s.io' | sed 's/^/  api: /'
  h "2. PVC models and Job model-pull (oras from Harbor)"
  cat <<YAML | k -n $NS apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: models}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: k8s-990pro
  resources: {requests: {storage: 30Gi}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: model-pull}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      volumes:
      - {name: models, persistentVolumeClaim: {claimName: models}}
      - {name: creds, secret: {secretName: harbor-creds}}
      - {name: ca, configMap: {name: vis-ca}}
      containers:
      - name: oras
        image: ghcr.io/oras-project/oras:v1.3.0
        command: ["sh", "-c", "set -e; cd /models; oras pull $ART --registry-config /creds/.dockerconfigjson --ca-file /ca/ca.pem -o /models; echo '--- files'; ls -la /models; find /models -type f | head; df -h /models"]
        volumeMounts:
        - {name: models, mountPath: /models}
        - {name: creds, mountPath: /creds, readOnly: true}
        - {name: ca, mountPath: /ca, readOnly: true}
YAML
  for i in {1..60}; do
    S=$(k -n $NS get job model-pull -o jsonpath='{.status.succeeded}' 2>/dev/null); F=$(k -n $NS get job model-pull -o jsonpath='{.status.failed}' 2>/dev/null)
    print -r -- "  $(date +%T) model-pull succeeded=${S:-0} failed=${F:-0}"
    [[ ${S:-0} -ge 1 || ${F:-0} -ge 2 ]] && break
    sleep 10
  done
  k -n $NS logs job/model-pull 2>&1 | tail -15 | sed 's/^/  /'
  ;;
ts)
  h "test 5: TimeSlicing interval $TS_INTERVAL, two containers"
  k -n $NS delete pod share --ignore-not-found --wait=true >/dev/null 2>&1
  k -n $NS delete resourceclaimtemplate shared-gpu --ignore-not-found >/dev/null 2>&1   # spec is immutable
  share_pod "              strategy: TimeSlicing
              timeSlicingConfig:
                interval: $TS_INTERVAL" ab | k apply -f -
  wait_pod; status
  ;;
mps)
  h "test 6: MPS 50 percent threads, 10Gi pinned memory each, two containers"
  k -n $NS delete pod share --ignore-not-found --wait=true >/dev/null 2>&1
  k -n $NS delete resourceclaimtemplate shared-gpu --ignore-not-found >/dev/null 2>&1   # spec is immutable
  share_pod "              strategy: MPS
              mpsConfig:
                defaultActiveThreadPercentage: 50
                defaultPinnedDeviceMemoryLimit: 10Gi" ab | k apply -f -
  wait_pod; status
  ;;
solo)
  h "control: one container, TimeSlicing template"
  k -n $NS delete pod share --ignore-not-found --wait=true >/dev/null 2>&1
  k -n $NS delete resourceclaimtemplate shared-gpu --ignore-not-found >/dev/null 2>&1   # spec is immutable
  share_pod "              strategy: TimeSlicing" a | k apply -f -
  wait_pod; status
  ;;
bench)
  h "bench through port-forward (dra-bench.py, PAR=${PAR:-4} TOK=${TOK:-400})"
  [[ -f ~/dra-bench.py ]] || { print -r -- "~/dra-bench.py missing"; exit 1; }
  pkill -f "port-forward pod/share" 2>/dev/null; sleep 1
  PORTS=$(k -n $NS get pod share -o jsonpath='{range .spec.containers[*]}{.ports[0].containerPort}{" "}{end}')
  kubectl --kubeconfig $KC -n $NS port-forward pod/share $(for p in ${=PORTS}; do print -n -- "$p:$p "; done) >/tmp/dra-pf.log 2>&1 &
  PF=$!
  for p in ${=PORTS}; do
    for i in {1..30}; do curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$p/health 2>/dev/null | grep -q 200 && { print -r -- "  port $p healthy after $i tries"; break; }; sleep 2; done
  done
  python3 ~/dra-bench.py ${=PORTS}
  kill $PF 2>/dev/null; pkill -f "port-forward pod/share" 2>/dev/null
  tail -3 /tmp/dra-pf.log | sed 's/^/  pf: /'
  status
  ;;
clean)
  k -n $NS delete pod share --ignore-not-found; k -n $NS delete resourceclaimtemplate shared-gpu --ignore-not-found
  ;;
status) status ;;
*) print -r -- "MODE=prep|ts|mps|solo|status|clean" ;;
esac
print -r -- ""
print -r -- "done $(date +%T)"

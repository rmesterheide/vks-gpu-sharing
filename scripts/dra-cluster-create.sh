#!/bin/zsh
# DRA plan B, step 4 and 5 (2026-10-30): free the A5000 and create the VKS cluster gpu-dra in namespace pais.
#  free   : lab-fast route back to Ollama (needs ~/pais-route-lab-fast-local.yaml), delete ModelEndpoint gemma-4-12b-a5000,
#           wait until its worker VM is gone (the card is then free on the host)
#  create : apply the Cluster gpu-dra (VKr 1.36.4, ClusterClass builtin-generic-v3.7.0, CP best-effort-medium,
#           one worker a5000-passthrough with an 80Gi containerd volume (the default node disk ran out of ephemeral
#           storage while pulling the llama.cpp CUDA image, 2026-10-30 22:09), maxSurge 0 so the single card can move,
#           storage k8s-990pro, VIS root CA trusted, pod/service CIDRs away from the lab network)
#  status : machines, VMs, kubeconfig secret; writes /tmp/gpu-dra.kubeconfig when the secret exists
# Run on the MacBook after `kubectl vsphere login`:
#   MODE=all zsh ~/dra-cluster-create.sh 2>&1 | tee /tmp/dra-cluster-create.txt
#   MODE=status zsh ~/dra-cluster-create.sh 2>&1 | tee /tmp/dra-cluster-status.txt
set -u
MODE=${MODE:-status}
NS=${SUPERVISOR_NS:-pais}; CL=gpu-dra; MEP=gemma-4-12b-a5000
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1 || { print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }

status() {
  h "status of $CL"
  kubectl -n $NS get cluster $CL 2>&1 | head -3
  kubectl -n $NS get machines -l cluster.x-k8s.io/cluster-name=$CL -o custom-columns='MACHINE:.metadata.name,PHASE:.status.phase,VERSION:.spec.version,NODE:.status.nodeRef.name' --no-headers 2>/dev/null | sed 's/^/  /'
  kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,CLASS:.spec.className,POWER:.status.powerState,IP:.status.network.primaryIP4' --no-headers 2>/dev/null | sed 's/^/  /'
  kubectl -n $NS get kubeadmcontrolplane -l cluster.x-k8s.io/cluster-name=$CL --no-headers 2>/dev/null | sed 's/^/  kcp: /'
  kubectl -n $NS get cluster $CL -o jsonpath='{range .status.conditions[*]}{"  cond: "}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null | head -12
  if kubectl -n $NS get secret $CL-kubeconfig >/dev/null 2>&1; then
    kubectl -n $NS get secret $CL-kubeconfig -o jsonpath='{.data.value}' | base64 -d > /tmp/$CL.kubeconfig
    print -r -- "  kubeconfig written: /tmp/$CL.kubeconfig"
    kubectl --kubeconfig /tmp/$CL.kubeconfig get nodes -o wide 2>&1 | head -5 | sed 's/^/  /'
    kubectl --kubeconfig /tmp/$CL.kubeconfig api-versions 2>/dev/null | grep resource.k8s.io | sed 's/^/  dra api: /'
  else
    print -r -- "  kubeconfig secret not there yet"
  fi
}

if [[ $MODE == free || $MODE == all ]]; then
  h "1. lab-fast back to Ollama"
  if [[ -f ~/pais-route-lab-fast-local.yaml ]]; then
    kubectl -n $NS delete inferencegatewayroute lab-fast --ignore-not-found
    kubectl apply -f ~/pais-route-lab-fast-local.yaml
  else
    print -r -- "  ~/pais-route-lab-fast-local.yaml missing, lab-fast route left as is (restore later with MODE=back zsh ~/pais-part3-swap.sh)"
  fi
  h "2. delete ModelEndpoint $MEP and wait for its VM to disappear"
  kubectl -n $NS delete mep $MEP --ignore-not-found --wait=false
  for i in {1..30}; do
    N=$(kubectl -n $NS get vm --no-headers 2>/dev/null | grep -c "$MEP")
    print -r -- "  $(date +%T) endpoint VMs left: $N"
    [[ $N -eq 0 ]] && break
    sleep 10
  done
  kubectl -n $NS get vm --no-headers 2>/dev/null | sed 's/^/  vm: /'
fi

if [[ $MODE == create || $MODE == all ]]; then
  h "3. apply Cluster $CL"
  cat > /tmp/$CL-cluster.yaml <<YAML
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: gpu-dra
  namespace: $NS
spec:
  clusterNetwork:
    serviceDomain: cluster.local
    services:
      cidrBlocks: ["10.96.0.0/12"]
    pods:
      cidrBlocks: ["10.244.0.0/16"]
  topology:
    classRef:
      name: builtin-generic-v3.7.0
      namespace: vmware-system-vks-public
    version: v1.36.4+vmware.2-vkr.3
    controlPlane:
      replicas: 1
      metadata:
        annotations:
          run.tanzu.vmware.com/resolve-os-image: os-name=ubuntu,os-version=24.04
    workers:
      machineDeployments:
      - class: node-pool
        name: gpu
        replicas: 1
        failureDomain: zone01
        metadata:
          annotations:
            run.tanzu.vmware.com/resolve-os-image: os-name=ubuntu,os-version=24.04
        rollout:
          strategy:
            type: RollingUpdate
            rollingUpdate:
              maxSurge: 0
              maxUnavailable: 1
        variables:
          overrides:
          - name: vmClass
            value: a5000-passthrough
          - name: volumes
            value:
            - name: containerd
              mountPath: /var/lib/containerd
              capacity: 80Gi
              storageClass: k8s-990pro
    variables:
    - name: storageClass
      value: k8s-990pro
    - name: vmClass
      value: best-effort-medium
    - name: osConfiguration
      value:
        trust:
          additionalTrustedCAs:
          - caCert:
              content: |
                <registry root CA PEM, indented like this line; see manifests/cluster-gpu-dra.yaml>
YAML
  cp /tmp/$CL-cluster.yaml ~/$CL-cluster.yaml
  kubectl apply -f /tmp/$CL-cluster.yaml
  h "4. watch for 3 minutes"
  for i in {1..9}; do
    sleep 20
    kubectl -n $NS get machines -l cluster.x-k8s.io/cluster-name=$CL -o custom-columns='MACHINE:.metadata.name,PHASE:.status.phase' --no-headers 2>/dev/null | awk -v t=$(date +%T) '{print "  " t, $1, $2}'
  done
fi

status
print -r -- ""
print -r -- "done $(date +%T). Later: MODE=status zsh ~/dra-cluster-create.sh"

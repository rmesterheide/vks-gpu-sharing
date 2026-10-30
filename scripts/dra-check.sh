#!/bin/zsh
# DRA plan B, tests 1 and 2 (2026-10-30): read-only checks on the Supervisor and the PAIS VKS cluster.
#  1. DRA API group and DeviceClasses on the VKS cluster (Kubernetes 1.34.9)
#  2. container runtime version per node (CDI is on by default from containerd 2.0), GPU Operator CDI setting
#  3. Supervisor: VM classes, VKr releases, content library, what is in namespace pais
# Run on the MacBook after `kubectl vsphere login`:
#   scp <your-copy>/dra-check.sh ~/ && zsh ~/dra-check.sh 2>&1 | tee /tmp/dra-check.txt
set -u
NS=${SUPERVISOR_NS:-pais}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1 || { print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }
KC=/tmp/pais-vks.kubeconfig
VKS=$(kubectl -n $NS get secret -o name | grep -E '^secret/pais-[0-9]+-kubeconfig$' | head -1)
[[ -n $VKS ]] || { print -r -- "no VKS kubeconfig secret in $NS"; exit 1; }
kubectl -n $NS get $VKS -o jsonpath='{.data.value}' | base64 -d > $KC
k() { kubectl --kubeconfig $KC "$@"; }

h "1. DRA API group on the VKS cluster"
k version 2>/dev/null | grep -E 'Client|Server'
k api-resources 2>/dev/null | grep -E '^NAME|resource\.k8s\.io' || print -r -- "  resource.k8s.io: NOT FOUND"
k api-versions 2>/dev/null | grep resource.k8s.io || print -r -- "  no resource.k8s.io API versions"
print -r -- "--- deviceclasses / resourceslices (expected empty before the DRA driver)"
k get deviceclasses 2>&1 | head -5
k get resourceslices 2>&1 | head -5
print -r -- "--- kube-apiserver flags mentioning DRA or runtime-config"
k -n kube-system get pods -l component=kube-apiserver -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{"\n"}{end}' 2>/dev/null | grep -i -E 'feature-gates|runtime-config' || print -r -- "  (no explicit flags, defaults apply)"

h "2. nodes, container runtime, kubelet"
k get nodes -o wide 2>/dev/null
print -r -- "--- GPU Operator ClusterPolicy: cdi and toolkit settings"
k get clusterpolicies.nvidia.com -o jsonpath='{range .items[*]}{.metadata.name}{"  cdi.enabled="}{.spec.cdi.enabled}{"  cdi.default="}{.spec.cdi.default}{"  devicePlugin.enabled="}{.spec.devicePlugin.enabled}{"  toolkit.enabled="}{.spec.toolkit.enabled}{"\n"}{end}' 2>/dev/null || print -r -- "  no ClusterPolicy"
k -n gpu-operator get pods --no-headers 2>/dev/null | awk '{print "  ", $1, $3}'
print -r -- "--- toolkit container env (CDI related)"
TP=$(k -n gpu-operator get pods --no-headers 2>/dev/null | grep container-toolkit | awk '{print $1}' | head -1)
[[ -n $TP ]] && k -n gpu-operator get pod $TP -o jsonpath='{range .spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null | grep -i -E 'cdi|runtime' | sed 's/^/   /'
print -r -- "--- containerd config on the GPU node, read through the toolkit pod (host root under /host or /runtime)"
if [[ -n $TP ]]; then
  for f in /host/etc/containerd/config.toml /runtime/config-dir/config.toml /host/etc/containerd/conf.d/99-nvidia.toml; do
    k -n gpu-operator exec $TP -c nvidia-container-toolkit-ctr -- sh -c "test -f $f && echo '## $f' && grep -n -i -E 'enable_cdi|cdi_spec_dirs|default_runtime_name|version' $f" 2>/dev/null
  done
fi

h "3. Supervisor side: VM classes, VKr releases, namespace content"
kubectl get virtualmachineclasses --no-headers 2>/dev/null | awk '{print "  class:", $1}' | head -30
kubectl get virtualmachineclassbindings -n $NS --no-headers 2>/dev/null | awk '{print "  bound to pais:", $1}'
kubectl get tkr --no-headers 2>/dev/null | awk '{print "  tkr:", $1, $3, $4}'
kubectl get clusters.cluster.x-k8s.io -n $NS -o jsonpath='{range .items[*]}{"  cluster version: "}{.metadata.name}{" "}{.spec.topology.version}{" class "}{.spec.topology.class}{"\n"}{end}' 2>/dev/null
kubectl get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null | awk '{print "  cluster:", $1, $2, $3}'
kubectl get ns --no-headers 2>/dev/null | grep -v -E '^(kube-|vmware-|svc-)' | awk '{print "  supervisor ns:", $1}'
kubectl -n $NS get modelendpoints --no-headers 2>/dev/null | awk '{print "  endpoint:", $1, $2, $3}' || true
kubectl api-resources 2>/dev/null | grep -i -E 'modelendpoint|paisconfig' | awk '{print "  supervisor crd:", $1, $2}'
kubectl -n $NS get vm --no-headers 2>/dev/null | awk '{print "  vm:", $1, $2, $3, $4}'
print -r -- ""
print -r -- "done $(date +%T)"

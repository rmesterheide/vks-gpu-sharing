#!/bin/zsh
# DRA plan B, step 3 (2026-10-30): read the values a new VKS cluster in namespace pais needs. Read-only.
#  1. the PAIS cluster's topology (class, version, variables: storage class, VM classes, network)
#  2. storage classes, VM class bindings and content library visible in the namespace
#  3. current lab-fast route (so the swap back is documented)
# Run on the MacBook after `kubectl vsphere login`:
#   scp <your-copy>/dra-cluster-info.sh ~/ && zsh ~/dra-cluster-info.sh 2>&1 | tee /tmp/dra-cluster-info.txt
set -u
NS=${SUPERVISOR_NS:-pais}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1 || { print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }

h "1. PAIS cluster topology (spec.topology without status)"
C=$(kubectl -n $NS get clusters.cluster.x-k8s.io -o name | head -1)
print -r -- "cluster: $C"
kubectl -n $NS get $C -o jsonpath='{.spec.topology}' | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))' 2>/dev/null | head -120
print -r -- "--- clusterclasses available"
kubectl -n $NS get clusterclasses --no-headers 2>/dev/null | awk '{print "  class:", $1}'
kubectl get clusterclasses -A --no-headers 2>/dev/null | awk '{print "  class (all ns):", $1, $2}' | head

h "2. storage classes, VM classes, content library in the namespace"
kubectl -n $NS get resourcequota -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.hard}{"\n"}{end}' 2>/dev/null
kubectl get storageclass --no-headers 2>/dev/null | awk '{print "  storageclass:", $1, $2}'
kubectl -n $NS get virtualmachineclassbindings --no-headers 2>/dev/null | awk '{print "  vmclass binding:", $1}'
kubectl -n $NS get virtualmachineclass a5000-passthrough -o jsonpath='{.spec.hardware}{"\n"}' 2>/dev/null
kubectl -n $NS get contentlibraryproviders,contentsources --no-headers 2>/dev/null | awk '{print "  content:", $1}'
kubectl -n $NS get virtualmachineimages --no-headers 2>/dev/null | grep -i -E '1\.36\.4|1\.35\.8|1\.34\.9' | awk '{print "  image:", $1, $2, $3}'
print -r -- "--- tkr 1.36.4 details"
kubectl get tkr v1.36.4---vmware.2-vkr.3 -o jsonpath='{.spec.version}{"  images: "}{range .spec.osImages[*]}{.name}{" "}{end}{"\n"}' 2>/dev/null
kubectl get osimages -A --no-headers 2>/dev/null | grep -i '1.36.4' | awk '{print "  osimage:", $1, $2}'

h "3. PAIS side: endpoints, routes, lab-fast"
kubectl -n $NS get mep --no-headers 2>/dev/null | awk '{print "  endpoint:", $1, $2, $3}'
kubectl -n $NS get pcfg -o jsonpath='{range .items[*]}{.metadata.name}{"  gpuDriverType="}{.spec.nvidiaConfig.gpuDriverType}{"  operator="}{.spec.nvidiaConfig.gpuOperatorVersion}{"\n"}{end}' 2>/dev/null
kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,CLASS:.spec.className,POWER:.status.powerState' --no-headers 2>/dev/null | sed 's/^/  /'
print -r -- ""
print -r -- "done $(date +%T)"

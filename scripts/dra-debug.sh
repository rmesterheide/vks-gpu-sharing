#!/bin/zsh
# DRA plan B (2026-10-30 21:47): why do no pods appear in gpu-operator and dra-test? Read-only.
#   zsh ~/dra-debug.sh 2>&1 | tee /tmp/dra-debug.txt
set -u
KC=/tmp/gpu-dra.kubeconfig
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
k() { kubectl --kubeconfig $KC "$@"; }

h "1. all pods in the cluster (any namespace)"
k get pods -A -o wide 2>&1 | head -60
h "2. deployments, replicasets, jobs in gpu-operator and dra-test"
k -n gpu-operator get deploy,rs,ds,job 2>&1
k -n dra-test get deploy,rs,job,pvc 2>&1
h "3. replicaset / job descriptions (events at the bottom)"
for rs in $(k -n gpu-operator get rs -o name 2>/dev/null); do k -n gpu-operator describe $rs 2>&1 | grep -A12 '^Events' ; done
k -n dra-test describe job model-pull 2>&1 | grep -A12 '^Events'
k -n dra-test describe pvc models 2>&1 | grep -A8 '^Events'
h "4. warning events, newest last"
k get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -40 | cut -c1-240
h "5. all events in gpu-operator and dra-test"
k -n gpu-operator get events --sort-by=.lastTimestamp 2>&1 | tail -25 | cut -c1-240
k -n dra-test get events --sort-by=.lastTimestamp 2>&1 | tail -25 | cut -c1-240
h "6. namespace labels (pod security admission)"
k get ns gpu-operator dra-test default kube-system --show-labels 2>&1
h "7. control plane components and webhooks"
k -n kube-system get pods -o wide 2>&1 | head -30
k get validatingwebhookconfigurations,mutatingwebhookconfigurations 2>&1
k get validatingadmissionpolicies,validatingadmissionpolicybindings 2>&1 | head
h "8. gpucluster and nvidiadriver details"
k describe gpucluster gpu-cluster 2>&1 | grep -v -E '^\s*$' | tail -40 | cut -c1-240
k get nvidiadriver default -o jsonpath='{.status}' 2>&1 | cut -c1-600; print
h "9. helm status"
helm --kubeconfig $KC -n gpu-operator status gpu-operator 2>&1 | head -12
helm --kubeconfig $KC -n gpu-operator get manifest gpu-operator 2>/dev/null | grep -E '^kind:' | sort | uniq -c
print -r -- ""
print -r -- "done $(date +%T)"

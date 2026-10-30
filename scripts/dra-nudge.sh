#!/bin/zsh
# DRA plan B (2026-10-30 22:02): after the pod-security labels, make the controllers retry now instead of after
# their backoff. 1. test pod proves the namespace accepts plain pods, 2. rollout restart of the operator workloads,
# 3. Job model-pull recreated through dra-share.sh MODE=prep (waits for the pull), 4. operator status.
#   zsh ~/dra-nudge.sh 2>&1 | tee /tmp/dra-nudge.txt
set -u
KC=/tmp/gpu-dra.kubeconfig
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
k() { kubectl --kubeconfig $KC "$@"; }

h "1. test pod in dra-test (plain busybox, no securityContext)"
k -n dra-test delete pod psa-test --ignore-not-found >/dev/null 2>&1
k -n dra-test run psa-test --image=busybox:1.37 --restart=Never --command -- sh -c 'echo pod-security ok; id' 2>&1
sleep 15
k -n dra-test get pod psa-test 2>&1 | sed 's/^/  /'
k -n dra-test logs psa-test 2>&1 | sed 's/^/  log: /'
k -n dra-test delete pod psa-test --ignore-not-found >/dev/null 2>&1

h "2. rollout restart in gpu-operator"
k -n gpu-operator rollout restart deployment 2>&1
k -n gpu-operator rollout restart daemonset 2>&1
sleep 20
k -n gpu-operator get pods -o wide 2>&1 | sed 's/^/  /'

h "3. recreate Job model-pull (dra-share.sh MODE=prep waits for the pull)"
k -n dra-test delete job model-pull --ignore-not-found 2>&1
MODE=prep zsh ~/dra-share.sh

h "4. operator status"
MODE=status zsh ~/dra-install.sh
print -r -- ""
print -r -- "done $(date +%T)"

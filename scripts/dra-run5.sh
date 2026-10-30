#!/bin/zsh
# DRA plan B, the measurement chain (2026-10-30 22:06): one command for tests 3 to 6.
#  a. wait for the driver and the ResourceSlice of the A5000 (up to 10 min)
#  b. test 4: whole GPU through a claim, nvidia-smi (dra-install.sh MODE=claim)
#  c. control: one llama-server container under a TimeSlicing template, bench
#  d. test 5: two containers, TimeSlicing Default, bench; then TimeSlicing Long, bench
#  e. test 6: two containers, MPS 50/50, bench
#  f. clean up the pod, final status
# Needs ~/dra-install.sh, ~/dra-share.sh, ~/dra-bench.py and /tmp/gpu-dra.kubeconfig. Env: PAR=4 TOK=400.
#   zsh ~/dra-run5.sh 2>&1 | tee /tmp/dra-run5.txt
set -u
KC=/tmp/gpu-dra.kubeconfig
export PAR=${PAR:-4} TOK=${TOK:-400}
h() { print -r -- ""; print -r -- "##### $*  ($(date +%T))"; }
# FROM=d1 skips everything before step d1 (steps: a b c d1 d2 e f)
FROM=${FROM:-a}; ORDER=(a b c d1 d2 e f)
run() { local want=${ORDER[(i)$1]} have=${ORDER[(i)$FROM]}; (( want >= have )); }
k() { kubectl --kubeconfig $KC "$@"; }
for f in ~/dra-install.sh ~/dra-share.sh ~/dra-bench.py; do [[ -f $f ]] || { print -r -- "$f missing"; exit 1; }; done
LOCK=/tmp/dra-run5.lock
if [[ -f $LOCK ]] && kill -0 $(cat $LOCK) 2>/dev/null; then print -r -- "another dra-run5.sh is running (pid $(cat $LOCK)); stop it first (Ctrl-C in its tab or: kill $(cat $LOCK))"; exit 1; fi
print $$ > $LOCK; trap 'rm -f $LOCK' EXIT
h "0. clean start: no leftover test pods"
k -n dra-test delete pod share smi --ignore-not-found --wait=true 2>&1 | sed 's/^/  /'
k -n dra-test delete resourceclaimtemplate shared-gpu single-gpu --ignore-not-found 2>&1 | sed 's/^/  /'
k -n dra-test get pods,resourceclaims 2>&1 | sed 's/^/  /'

if run a; then
h "a. wait for the GPU node, the driver and the ResourceSlice (up to 20 min)"
for i in {1..60}; do
  S=$(k get resourceslices --no-headers 2>/dev/null | wc -l | tr -d ' ')
  P=$(k -n gpu-operator get pods --no-headers 2>/dev/null | grep -v -E ' Running | Completed ' | awk '{print $1":"$3}' | tr '\n' ' ')
  G=$(k get gpucluster gpu-cluster -o jsonpath='{.status.state}' 2>/dev/null)
  NODE=$(k get resourceslices -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  NR=$(k get node $NODE -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
  ES=$(k get node $NODE -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null)
  print -r -- "  $(date +%T) gpucluster=${G:--} slices=$S node=${NODE:--} ready=${NR:--} ephemeral=${ES:--} notready: ${P:-none}"
  [[ $S -ge 1 && $NR == True && -z $P ]] && break
  sleep 20
done
[[ $S -ge 1 && $NR == True ]] || { print -r -- "no ready GPU node with a ResourceSlice after 20 min, stopping"; MODE=status zsh ~/dra-install.sh; exit 1; }
k get resourceslices -o jsonpath='{range .items[*].spec.devices[*]}{.name}{": "}{.attributes}{"\n"}{end}' 2>/dev/null | cut -c1-900 | sed 's/^/  attrs: /'
fi
if run b; then h "b. test 4: whole GPU through a claim"; MODE=claim zsh ~/dra-install.sh; fi
if run c; then h "c. control: one container"; MODE=solo zsh ~/dra-share.sh; MODE=bench zsh ~/dra-share.sh; fi
if run d1; then h "d1. test 5: TimeSlicing Default, two containers"; MODE=ts TS_INTERVAL=Default zsh ~/dra-share.sh; MODE=bench zsh ~/dra-share.sh; fi
if run d2; then h "d2. test 5: TimeSlicing Long, two containers"; MODE=ts TS_INTERVAL=Long zsh ~/dra-share.sh; MODE=bench zsh ~/dra-share.sh; fi
if run e; then h "e. test 6: MPS 50/50, two containers"; MODE=mps zsh ~/dra-share.sh; MODE=bench zsh ~/dra-share.sh; fi

h "f. clean up and final status"
MODE=clean zsh ~/dra-share.sh
MODE=status zsh ~/dra-install.sh
print -r -- ""
print -r -- "done $(date +%T)"

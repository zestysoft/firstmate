#!/usr/bin/env bash
# drive: start pi suite, wait until pi-retry-dead-root exists, send signal, report leftovers
sig=$1; out=$2
bash tests/fm-pi-watch-extension.test.sh > "$out.log" 2>&1 &
runner=$!
for i in $(seq 1 1200); do
  if ps -axo args= | grep -v grep | grep -q 'pi-retry-dead-root'; then break; fi
  sleep 0.05
done
echo "saw pi-retry-dead-root processes after $((i*50))ms:" 
ps -axo pid=,ppid=,pgid=,args= | grep -v grep | grep 'fm-pi-watch-extension\.' | head -20
root=$(ps -axo args= | grep -v grep | grep -o '/[^ ]*/fm-pi-watch-extension\.[A-Za-z0-9]*' | head -1)
echo "TMP_ROOT=$root"
echo "sending SIG$sig to runner $runner"
if [ "$sig" = KILL ]; then
  # kill runner and its whole job group except the stub children, mimicking a hard kill
  kill -KILL "$runner"
else
  kill -s "$sig" "$runner"
fi
wait "$runner" 2>/dev/null; echo "runner rc=$?"
sleep 3
if [ "$sig" = KILL ]; then
  echo "processes naming TMP_ROOT after SIGKILL (before root removal):"
  ps -axo pid=,ppid=,args= | grep -v grep | grep -F "$root" 
  echo "removing root $root (as fm_test_reap_orphans would)"; rm -rf "$root"; sleep 2
fi
echo "processes naming TMP_ROOT at end:"
ps -axo pid=,ppid=,args= | grep -v grep | grep -F "$root" || echo "NONE"
echo "parent-pid-1 processes from fm-pi-watch-extension temp paths:"
ps -axo pid=,ppid=,args= | awk '$2==1' | grep -v grep | grep 'fm-pi-watch-extension' || echo "NONE"

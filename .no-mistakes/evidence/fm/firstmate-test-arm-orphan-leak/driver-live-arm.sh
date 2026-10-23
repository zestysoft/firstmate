#!/usr/bin/env bash
# Live drive of the real bin/fm-watch-arm.sh --restart in a disposable root, then delete the root.
# usage: live-arm.sh <label> <git-rev> <mode: owned|attached>
set -u
label=$1 rev=$2 mode=$3 WT=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-arm.XXXXXX"); T=$(cd -P "$T" && pwd -P)
root="$T/root"; fakebin="$T/fakebin"; mkdir -p "$root/data" "$fakebin"
git -C "$WT" archive "$rev" bin | tar -x -C "$root"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"; chmod +x "$fakebin/tmux"
run_arm() { env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  PATH="$fakebin:$PATH" FM_HOME="$root" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=60 bash "$root/bin/fm-watch-arm.sh" "$@"; }
echo "== $label rev=$rev mode=$mode root=$root"
run_arm --restart > "$T/owner.out" 2>&1 & owner=$!
for i in $(seq 1 100); do grep -q '^watcher: started' "$T/owner.out" && break; sleep 0.1; done
cat "$T/owner.out"
target=$owner
if [ "$mode" = attached ]; then
  run_arm > "$T/att.out" 2>&1 & target=$!
  for i in $(seq 1 100); do grep -q '^watcher: attached' "$T/att.out" && break; sleep 0.1; done
  cat "$T/att.out"
fi

echo "removing root"; start=$(perl -MTime::HiRes=time -e 'printf "%.2f",time')
rm -rf "$root"; echo "rm took $(perl -MTime::HiRes=time -e "printf q(%.2f), time-$start")s"
gone=no
for i in $(seq 1 100); do kill -0 "$target" 2>/dev/null || { gone=yes; break; }; sleep 0.1; done
end=$(perl -MTime::HiRes=time -e 'printf "%.2f",time')
wait "$target" 2>/dev/null; rc=$?
echo "arm under test exited=$gone rc=$rc after $(perl -e "printf '%.2f', $end-$start")s (10s cap)"
echo "-- owner arm output:"; cat "$T/owner.out"; [ "$mode" = attached ] && { echo "-- attached arm output:"; cat "$T/att.out"; }
for i in $(seq 1 100); do kill -0 "$owner" 2>/dev/null || break; sleep 0.1; done; echo "owner arm alive after extra wait: $(kill -0 $owner 2>/dev/null && echo yes || echo no)"
echo "-- processes still naming $T:"
ps -axo pid=,ppid=,args= | grep -v grep | grep -F "$T" || echo NONE
# teardown: kill anything left and remove temp
pkill -f "$T" 2>/dev/null; sleep 0.5; pkill -9 -f "$T" 2>/dev/null; rm -rf "$T"

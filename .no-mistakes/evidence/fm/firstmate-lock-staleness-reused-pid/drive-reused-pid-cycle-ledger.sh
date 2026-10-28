#!/usr/bin/env bash
# Live drive: the real bin/fm-watch-arm.sh in a disposable marked lab home whose
# cycle-ledger lock (state/.watch-cycle-exits.lock) is recorded as held by a
# dead holder whose pid now belongs to an unrelated live process.
# Usage: drive-reused-pid-cycle-ledger.sh <bin-dir> <label>
set -u
BIN=$1
LABEL=$2
WT=~/.no-mistakes/worktrees/260e8caa837a/01M60KPTW4AV25CTAGJZQA2C1H
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
STATE="$LAB/state"
ARMOUT="$LAB/arm.out"

# The unrelated process that "reused" the dead holder's pid.
sleep 600 &
UNRELATED=$!
# The original holder's start time: launchd (pid 1) started before the unrelated
# process, so it can never be the unrelated process's start time.
HOLDER_START=$(LC_ALL=C TZ=UTC0 ps -p 1 -o lstart= | sed 's/^ *//; s/ *$//')
OWNER="$STATE/.watch-cycle-exits.lock.owner.stale"
mkdir "$OWNER"
printf '%s\n' "$UNRELATED" > "$OWNER/pid"
printf '%s\n' "$HOLDER_START" > "$OWNER/pid-start"
ln -s "$OWNER" "$STATE/.watch-cycle-exits.lock"
echo "[$LABEL] planted lock: pid=$UNRELATED (live: $(ps -p "$UNRELATED" -o comm=), started $(LC_ALL=C TZ=UTC0 ps -p "$UNRELATED" -o lstart=)) recorded pid-start='$HOLDER_START'"

cleanup() {
  [ -n "${ARM:-}" ] && kill "$ARM" 2>/dev/null
  W=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$W" ] && kill "$W" 2>/dev/null
  sleep 1
  kill "$UNRELATED" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$BIN/fm-watch-arm.sh" > "$ARMOUT" 2>&1 &
ARM=$!
for _ in $(seq 1 200); do
  grep -q '^watcher: started pid=' "$ARMOUT" 2>/dev/null && break
  sleep 0.1
done
echo "[$LABEL] arm output so far:"; sed 's/^/    /' "$ARMOUT"
WATCHER=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
[ -n "$WATCHER" ] || { echo "[$LABEL] RESULT: watcher never started"; exit 3; }
echo "[$LABEL] ending the watcher cycle: kill -TERM $WATCHER"
kill -TERM "$WATCHER"
for _ in $(seq 1 100); do
  kill -0 "$ARM" 2>/dev/null || break
  sleep 0.1
done
echo "[$LABEL] arm exited: $(kill -0 "$ARM" 2>/dev/null && echo no || echo yes)"
echo "[$LABEL] arm final output:"; sed 's/^/    /' "$ARMOUT"
echo "[$LABEL] cycle ledger (.watch-cycle-exits.log):"
if [ -s "$STATE/.watch-cycle-exits.log" ]; then sed 's/^/    /' "$STATE/.watch-cycle-exits.log"; else echo "    <no rows>"; fi
echo "[$LABEL] cycle-ledger lock now: $(readlink "$STATE/.watch-cycle-exits.lock" 2>/dev/null || echo '<released>') pid=$(cat "$STATE/.watch-cycle-exits.lock/pid" 2>/dev/null || echo none)"
echo "[$LABEL] unrelated pid $UNRELATED still alive (not signalled): $(kill -0 "$UNRELATED" 2>/dev/null && echo yes || echo no)"
if [ -s "$STATE/.watch-cycle-exits.log" ]; then echo "[$LABEL] RESULT: ledger row written"; else echo "[$LABEL] RESULT: ledger NOT written (lock stuck)"; fi

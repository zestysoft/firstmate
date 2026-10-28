#!/usr/bin/env bash
# Live drive of the real bin/fm-watch-arm.sh in a disposable lab home against
# three cycle-ledger lock states:
#   live-holder : a real process took the lock through fm-wake-lib and is alive
#   legacy      : record has a live pid but NO pid-start (pre-fix record)
#   dead        : record has a dead pid plus a pid-start
# Usage: drive-guard-cases.sh <bin-dir> <mode>
set -u
BIN=$1; MODE=$2
WT=~/.no-mistakes/worktrees/260e8caa837a/01M60KPTW4AV25CTAGJZQA2C1H
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
STATE="$LAB/state"; ARMOUT="$LAB/arm.out"; LOCK="$STATE/.watch-cycle-exits.lock"
HOLDER=
case "$MODE" in
  live-holder)
    FM_HOME="$LAB" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 10; touch "$3"; while [ ! -e "$4" ]; do sleep 0.05; done; fm_lock_release "$2"' \
      _ "$BIN/fm-wake-lib.sh" "$LOCK" "$LAB/ready" "$LAB/release" &
    HOLDER=$!
    for _ in $(seq 1 100); do [ -e "$LAB/ready" ] && break; sleep 0.05; done
    echo "[$MODE] real holder pid=$HOLDER took lock; record pid=$(cat "$LOCK/pid") pid-start='$(cat "$LOCK/pid-start" 2>/dev/null)'; live lstart='$(LC_ALL=C TZ=UTC0 ps -p "$HOLDER" -o lstart= | sed 's/ *$//')'" ;;
  legacy)
    sleep 600 & HOLDER=$!
    mkdir "$LOCK.owner.legacy"; printf '%s\n' "$HOLDER" > "$LOCK.owner.legacy/pid"; ln -s "$LOCK.owner.legacy" "$LOCK"
    echo "[$MODE] planted pre-fix record: pid=$HOLDER (live), no pid-start file" ;;
  dead)
    sleep 0 & DEAD=$!; wait "$DEAD"
    mkdir "$LOCK.owner.dead"; printf '%s\n' "$DEAD" > "$LOCK.owner.dead/pid"
    LC_ALL=C TZ=UTC0 ps -p 1 -o lstart= | sed 's/^ *//; s/ *$//' > "$LOCK.owner.dead/pid-start"
    ln -s "$LOCK.owner.dead" "$LOCK"
    echo "[$MODE] planted record: pid=$DEAD (alive? $(kill -0 $DEAD 2>/dev/null && echo yes || echo no)) with pid-start" ;;
esac
cleanup() { kill "${ARM:-}" 2>/dev/null; W=$(cat "$STATE/.watch.lock/pid" 2>/dev/null); [ -n "$W" ] && kill "$W" 2>/dev/null; touch "$LAB/release"; sleep 1; [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; wait 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$BIN/fm-watch-arm.sh" > "$ARMOUT" 2>&1 &
ARM=$!
for _ in $(seq 1 200); do grep -q '^watcher: started pid=' "$ARMOUT" 2>/dev/null && break; sleep 0.1; done
W=$(cat "$STATE/.watch.lock/pid" 2>/dev/null); [ -n "$W" ] || { echo "[$MODE] watcher never started: $(cat "$ARMOUT")"; exit 3; }
kill -TERM "$W"
for _ in $(seq 1 100); do kill -0 "$ARM" 2>/dev/null || break; sleep 0.1; done
echo "[$MODE] arm output:"; sed 's/^/    /' "$ARMOUT"
echo "[$MODE] cycle ledger rows: $(wc -l < "$STATE/.watch-cycle-exits.log" 2>/dev/null | tr -d ' ' || echo 0)"
echo "[$MODE] lock after: pid=$(cat "$LOCK/pid" 2>/dev/null || echo '<released>')"
[ -n "$HOLDER" ] && echo "[$MODE] holder $HOLDER still alive: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no)"

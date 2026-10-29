#!/usr/bin/env bash
# Drive the real fm_lock_reap_dead_link / fm_lock_try_acquire against disposable
# state with real processes. Usage: drive-tombstone.sh <bin-dir> <label>
set -u
BIN=$1; LABEL=$2; LIB="$BIN/fm-wake-lib.sh"
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tomb.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; rm -rf "$SCR"' EXIT
say() { printf '[%s] %s\n' "$LABEL" "$*"; }
dead_pid() { bash -c 'echo $$'; }
lib() { FM_STATE_OVERRIDE="$1" bash -c '. "$1"; shift; "$@"' _ "$LIB" "${@:2}"; }

# Start a real reaper; pause it at its unlink after it renamed the owner to its tombstone.
start_paused_reaper() {  # <state> <lockdir>
  local state=$1 lock=$2 i=0
  rm -f "$SCR/ready" "$SCR/release"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"; lock=$2; ready=$3; release=$4
    rm() { if [ "${!#}" = "$lock" ]; then : > "$ready"; while [ ! -e "$release" ]; do sleep 0.05; done; fi; command rm "$@"; }
    fm_lock_reap_dead_link "$lock"' _ "$LIB" "$lock" "$SCR/ready" "$SCR/release" &
  REAPER=$!
  while [ $i -lt 100 ] && [ ! -e "$SCR/ready" ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$SCR/ready" ]
}
fixture() {  # <name> -> sets STATE LOCK OWNER; steal link to a dead owner
  STATE="$SCR/$1/state"; mkdir -p "$STATE"
  LOCK="$STATE/.contend.lock.steal"; OWNER="$LOCK.owner.fixture"
  mkdir "$OWNER"; dead_pid > "$OWNER/pid"; ln -s "$OWNER" "$LOCK"
}
tombs() { ls -d "$OWNER".reaped.* 2>/dev/null | sed "s|^$OWNER||"; }

sleep 300 & UNRELATED=$!   # stands in for a program that later got the dead reaper's pid
sleep 2                    # macOS lstart has 1-second precision; force distinct starts
say "unrelated live pid=$UNRELATED start='$(ps -p $UNRELATED -o lstart=)'"

echo; say "S1: a reaper is mid-cleanup and alive; a second cleaner runs"
fixture s1; start_paused_reaper "$STATE" "$LOCK" || say "reaper never paused"
say "live reaper pid=$REAPER tombstone: $(tombs)"
rc=0; lib "$STATE" fm_lock_reap_dead_link "$LOCK" || rc=$?
say "second cleaner rc=$rc; link still present: $([ -L "$LOCK" ] && echo yes || echo no); tombstone: $(tombs)"
: > "$SCR/release"; wait $REAPER; say "live reaper finished rc=$?; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstones left: $(tombs | wc -l | tr -d ' ')"

echo; say "S2: reaper died mid-cleanup and its pid was recycled by an unrelated live program"
fixture s2; start_paused_reaper "$STATE" "$LOCK"; T=$(ls -d "$OWNER".reaped.*)
kill -KILL $REAPER; wait $REAPER 2>/dev/null
mv -- "$T" "$OWNER.reaped.$UNRELATED${T#"$OWNER.reaped.$REAPER"}"
say "tombstone now names live pid: $(tombs)"
rc=0; lib "$STATE" fm_lock_reap_dead_link "$LOCK" || rc=$?
say "cleaner rc=$rc; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstones left: $(tombs | wc -l | tr -d ' '); unrelated alive: $(kill -0 $UNRELATED 2>/dev/null && echo yes || echo no)"

echo; say "S3: same recycled-pid wedge on the steal mutex; a real caller tries to take the dead-held lock"
STATE="$SCR/s3/state"; mkdir -p "$STATE"; PRIMARY="$STATE/.contend.lock"
lib "$STATE" fm_lock_try_create "$PRIMARY"; say "primary created by an exited holder pid=$(cat "$PRIMARY/pid")"
LOCK="$PRIMARY.steal"; OWNER="$LOCK.owner.fixture"; mkdir "$OWNER"; dead_pid > "$OWNER/pid"; ln -s "$OWNER" "$LOCK"
start_paused_reaper "$STATE" "$LOCK"; T=$(ls -d "$OWNER".reaped.*); kill -KILL $REAPER; wait $REAPER 2>/dev/null
mv -- "$T" "$OWNER.reaped.$UNRELATED${T#"$OWNER.reaped.$REAPER"}"
say "steal tombstone: $(tombs)"
rc=0; out=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_lock_try_acquire "$2"; r=$?; echo "held_pid=${FM_LOCK_HELD_PID:-} recovered=${FM_LOCK_RECOVERED_PID:-} mypid=$BASHPID new_owner_pid=$(cat "$2/pid" 2>/dev/null)"; exit $r' _ "$LIB" "$PRIMARY") || rc=$?
say "fm_lock_try_acquire rc=$rc $out"

echo; say "S4 (guard): legacy pid-only tombstone naming a live pid is still respected"
fixture s4; rmdir "$OWNER" 2>/dev/null || rm -rf "$OWNER"; mkdir "$OWNER.reaped.$UNRELATED"
rc=0; lib "$STATE" fm_lock_reap_dead_link "$LOCK" || rc=$?
say "cleaner rc=$rc; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstone: $(tombs)"

echo; say "S5 (guard): start-time probe unavailable for the live pid -> still respected"
fixture s5; rm -rf "$OWNER"; mkdir "$OWNER.reaped.$UNRELATED.start-deadbeef"
rc=0; FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_start_time() { return 1; }; fm_lock_reap_dead_link "$2"' _ "$LIB" "$LOCK" || rc=$?
say "cleaner rc=$rc; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstone: $(tombs)"

echo; say "S6 (guard): malformed empty '.start-' suffix on a live pid -> still respected"
fixture s6; rm -rf "$OWNER"; mkdir "$OWNER.reaped.$UNRELATED.start-"
rc=0; lib "$STATE" fm_lock_reap_dead_link "$LOCK" || rc=$?
say "cleaner rc=$rc; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstone: $(tombs)"

echo; say "S7: tombstone of a dead reaper (pid gone, no reuse) is still cleaned"
fixture s7; rm -rf "$OWNER"; D=$(dead_pid); mkdir "$OWNER.reaped.$D.start-00"
rc=0; lib "$STATE" fm_lock_reap_dead_link "$LOCK" || rc=$?
say "cleaner rc=$rc; link present: $([ -L "$LOCK" ] && echo yes || echo no); tombstones left: $(tombs | wc -l | tr -d ' ')"

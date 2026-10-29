#!/usr/bin/env bash
# Live drive: run the REAL bin/fm-watch.sh against a disposable lab FM_HOME and
# an isolated fm-lab-* Herdr session, then fire real Herdr agent-status edges at
# (a) a window whose task record was retired while the watcher's wait was open
# and (b) a window a live task record still owns.
#
# Usage: drive-leftover-endpoint.sh <bin-dir-under-test> <label> <out-dir> <rounds>
#   rounds = number of leftover edges to fire before the live-task edge.
set -u
BIN=$1; LABEL=$2; OUT=$3; ROUNDS=${4:-2}
WT=~/.no-mistakes/worktrees/260e8caa837a/01M643ZT4JDP8FCZJWPCFVVQ0P
cd "$WT" || exit 1
mkdir -p "$OUT"
: > "$OUT/transcript.txt"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/transcript.txt"; }

# shellcheck source=/dev/null
. "$WT/bin/fm-herdr-lab.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESSION=$(fm_herdr_lab_name "$LABEL")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
WPID=
cleanup() {
  if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null; then kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
  pkill -f "herdr-eventwait.py.*$SESSION" 2>/dev/null || true
  if fm_herdr_lab_teardown "$SESSION"; then log "teardown: lab session $SESSION removed, fleet tripwire unchanged"; else log "teardown: FAILED for $SESSION"; fi
  rm -rf "$LAB"
}
trap cleanup EXIT

"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { log "lab home create failed"; exit 1; }
STATE="$LAB/state"
fm_herdr_lab_provision "$SESSION" || { log "provision failed"; exit 1; }
export HERDR_SESSION="$SESSION"
# shellcheck source=/dev/null
. "$WT/bin/fm-backend.sh"
fm_backend_source herdr || exit 1
C_RAW=$(fm_backend_herdr_container_ensure /tmp) || { log "container_ensure failed"; exit 1; }
CONTAINER=${C_RAW%%$'\t'*}; SEED=${C_RAW#*$'\t'}
read -r _t PANE_L <<<"$(fm_backend_herdr_create_task "$CONTAINER" fm-live /tmp "$SEED")"
read -r _t PANE_R <<<"$(fm_backend_herdr_create_task "$CONTAINER" fm-retired /tmp "")"
WIN_L="$SESSION:$PANE_L"; WIN_R="$SESSION:$PANE_R"
log "lab: FM_HOME=$LAB session=$SESSION live window=$WIN_L retired window=$WIN_R bin=$BIN"

report() { fm_herdr_lab_cli "$SESSION" pane report-agent "$1" --source fm-leftover-test --agent claude --state "$2" >/dev/null 2>&1; }
write_meta() { printf 'window=%s\nbackend=herdr\nkind=ship\n' "$2" > "$STATE/$1.meta"; }
# Both panes report a busy agent so the ordinary poll-path idle timer stays
# quiet and only the push edges under test can wake the watcher.
report "$PANE_L" working; report "$PANE_R" working
# A ticking clock keeps each pane's content changing, so the poll path never
# sees two identical captures in a row (its idle-pane stale rule).
for p in "$PANE_L" "$PANE_R"; do
  fm_herdr_lab_cli "$SESSION" pane run "$p" 'while :; do date +%s.%N; sleep 1; done' >/dev/null 2>&1
done
write_meta live "$WIN_L"; write_meta retired "$WIN_R"

# Wait until the watcher's real Herdr subscriber is open and covers <pane>.
wait_reader_for() {
  local i=0
  while [ "$i" -lt 400 ]; do
    ps -axo args= | grep 'herdr-eventwait.py' | grep -v grep | grep -q -- " $1\( \|$\)" && return 0
    kill -0 "$WPID" 2>/dev/null || return 1
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
stale_rows() { awk -F '\t' -v w="$1" '$3 == "stale" && $4 == w' "$STATE/.wake-queue" 2>/dev/null; }

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_POLL=8 "$BIN/fm-watch.sh" > "$OUT/watch.stdout" 2> "$OUT/watch.stderr" &
WPID=$!
log "started real watcher pid=$WPID ($BIN/fm-watch.sh)"

r=1
while [ "$r" -le "$ROUNDS" ]; do
  if [ "$r" -gt 1 ]; then
    # The same leftover window comes back to work, then is retired again.
    write_meta retired "$WIN_R"; report "$PANE_R" working
    sleep 9
  fi
  wait_reader_for "$PANE_R" || { log "round $r: watcher exited or never subscribed (see stdout below)"; break; }
  log "round $r: watcher's live Herdr wait covers retired pane $PANE_R; retiring its task record (rm retired.meta) mid-wait"
  rm -f "$STATE/retired.meta"
  report "$PANE_R" blocked
  log "round $r: drove real Herdr edge: retired pane -> blocked"
  sleep 4
  if kill -0 "$WPID" 2>/dev/null; then
    log "round $r: watcher still running (no wake)"
  else
    wait "$WPID"; log "round $r: watcher EXITED rc=$? stdout: $(cat "$OUT/watch.stdout")"; WPID=; break
  fi
  r=$((r + 1))
done

log "stale rows for retired window: $(stale_rows "$WIN_R" | wc -l | tr -d ' ')"
log "triage-log leftover lines: $(grep -c 'leftover endpoint, no task record' "$STATE/.watch-triage.log" 2>/dev/null || echo 0)"

if [ -n "$WPID" ]; then
  wait_reader_for "$PANE_L" || log "live: watcher never subscribed to live pane"
  report "$PANE_L" blocked
  log "live: drove real Herdr edge: live task pane -> blocked"
  i=0; while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$WPID" 2>/dev/null; then log "live: watcher did NOT wake within 10s"; else wait "$WPID"; log "live: watcher exited rc=$? with wake line: $(cat "$OUT/watch.stdout")"; WPID=; fi
  log "stale rows for live window: $(stale_rows "$WIN_L" | wc -l | tr -d ' ')"
fi

cp "$STATE/.wake-queue" "$OUT/wake-queue.txt" 2>/dev/null || : > "$OUT/wake-queue.txt"
cp "$STATE/.watch-triage.log" "$OUT/watch-triage.log" 2>/dev/null || : > "$OUT/watch-triage.log"
ls -a "$STATE" > "$OUT/state-listing.txt"
log "done"

#!/usr/bin/env bash
# Live driver: a real Codex worker in a private lab tmux pane declares a wait
# ("paused: ..."), then the REAL bin/fm-watch.sh is started and restarted
# several times against a disposable lab FM_HOME. Counts fast stale alarms.
# Usage: live-declared-wait-restarts.sh <checkout-root> <label> <rounds> <secs-per-round>
set -u
ROOT=$1 LABEL=$2 ROUNDS=${3:-4} SECS=${4:-40} CHURN=${5:-0} BACKDATE=${6:-0}
EV=~/.no-mistakes/evidence/01M66SKVFE5BR7X6DG16RCDSR9
LOG="$EV/live-$LABEL.log"
: > "$LOG"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
SOCKDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
T() { TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab "$@"; }
cleanup() {
  T kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

CREW="$LAB/projects/crew-wt"; mkdir -p "$CREW"; git -C "$CREW" init -q
TASK=camera-question
WIN=lab:crew; KEY=lab_crew
S="$LAB/state"

# The worker: a real interactive Codex CLI in its own pane.
T new-session -d -s lab -n crew -x 200 -y 50 -c "$CREW" \
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" codex
printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\nworktree=%s\n' "$WIN" "$CREW" > "$S/$TASK.meta"
sleep 8
log "lab=$LAB root=$ROOT"
log "worker pane foreground: $(T display-message -p -t "$WIN" '#{pane_current_command}')"
# The worker correctly stands down and records what it is waiting on.
printf 'working: wiring the encounter camera\npaused: waiting for firstmate to answer the encounter camera question\n' > "$S/$TASK.status"
if [ "$BACKDATE" -gt 0 ]; then
  # The lane stood down BACKDATE seconds ago (e.g. hours before the night's restarts).
  touch -mt "$(date -r $(( $(date +%s) - BACKDATE )) '+%Y%m%d%H%M.%S')" "$S/$TASK.status"
fi
log "status declared (age ${BACKDATE}s): $(tail -1 "$S/$TASK.status")"

# Probe the same liveness + semantic verdict the watcher reads (from inside the lab server).
T new-window -d -t lab -n probe -c "$ROOT" "env -u NO_MISTAKES_GATE FM_HOME='$LAB' bash -c '
  . \"$ROOT/bin/fm-backend.sh\"; . \"$ROOT/bin/fm-busy-lib.sh\"
  printf \"agent_alive=%s\n\" \"\$(fm_backend_agent_alive tmux $WIN)\"
  printf \"busy_verdict=%s\n\" \"\$(fm_busy_classify_meta $S/$TASK.meta $TASK $S)\"
  printf \"crew_state=%s\n\" \"\$(\"$ROOT/bin/fm-crew-state.sh\" $TASK 2>&1 | head -1)\"
' > $LAB/probe.out 2>&1"
sleep 6; sed 's/^/probe: /' "$LAB/probe.out" | tee -a "$LOG"

ack() {
  local err seq gen
  err="$LAB/drain.err"
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >> "$LAB/drained.tsv" 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >> "$LAB/drained.tsv" 2>/dev/null
}

stale_total=0
for r in $(seq 0 "$ROUNDS"); do
  out="$LAB/watch.$r.out"; rcf="$LAB/watch.$r.rc"
  succ=""; [ "$r" -gt 0 ] && succ="FM_WATCH_HANDLING_SUCCESSOR=1"
  T new-window -d -t lab -n "watch$r" -c "$ROOT" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' $succ FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=14400 '$ROOT/bin/fm-watch.sh' > '$out' 2>'$out.err'; echo \$? > '$rcf'"
  t=0
  while [ ! -s "$rcf" ] && [ "$t" -lt "$SECS" ]; do
    sleep 1; t=$((t+1))
    # Pane churn: a keystroke lands in the live worker's composer (no Enter), so
    # the pane hash changes while the worker stays parked on its declared wait.
    if [ "$CHURN" = 1 ] && [ "$r" -gt 0 ] && [ $((t % 15)) -eq 0 ]; then
      T send-keys -t "$WIN" -l "x"; log "round $r: churned worker pane at ${t}s"
    fi
  done
  if [ -s "$rcf" ]; then
    log "round $r: watcher EXITED after ${t}s rc=$(cat "$rcf") reason: $(tr '\n' '|' < "$out")"
  else
    log "round $r: watcher still quietly running after ${SECS}s (no wake); paused-marker=$([ -e "$S/.paused-$KEY" ] && echo yes || echo no) stale-since=$([ -e "$S/.stale-since-$KEY" ] && echo yes || echo no)"
    T kill-window -t "lab:watch$r" 2>/dev/null; sleep 2
  fi
  n=$(grep -c "^stale: $WIN" "$out" 2>/dev/null); n=${n:-0}
  stale_total=$((stale_total + n))
  ack >/dev/null 2>&1
done
q=$(awk -F '\t' -v w="$WIN" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$LAB/drained.tsv" "$S/.wake-queue" 2>/dev/null)
log "worker pane still alive: $(T display-message -p -t "$WIN" '#{pane_current_command}')"
log "RESULT label=$LABEL churn=$CHURN status-age=${BACKDATE}s restarts=$ROUNDS stale-wakes-printed=$stale_total stale-wakes-queued=$q"
T capture-pane -p -t "$WIN" > "$EV/live-$LABEL-worker-pane.txt" 2>/dev/null

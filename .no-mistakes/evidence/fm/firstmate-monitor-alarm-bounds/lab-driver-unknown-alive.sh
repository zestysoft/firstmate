#!/usr/bin/env bash
# live.sh <evidence: status|none>  -- real tmux + real codex + real fm-watch.sh in a lab home
set -u
EV=$1; WT=/Users/Ian/.no-mistakes/worktrees/260e8caa837a/01M4V380NG6PV7MNENZ2SJW5CM
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
mkdir -p "$LAB/wt/src"; (cd "$LAB/wt" && git init -q)
T new-session -d -s lab -x 110 -y 40 -n primary
if [ "$EV" = dead ]; then T new-window -d -t lab -n fm-cx -c "$LAB/wt" "bash --norc -i"; else T new-window -d -t lab -n fm-cx -c "$LAB/wt" codex; fi
sleep 6
SOCK=$(T display -p '#{socket_path}'); SPID=$(T display -p '#{pid}')
W=lab:fm-cx; ST="$LAB/state"
printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$ST/cx.meta"
printf 'working: recovering source files\n' > "$ST/cx.status"
old=$(( $(date +%s) - 1000 )); stamp=$(date -r $old +%Y%m%d%H%M.%S)
: > "$LAB/wt/src/old.c"; touch -t "$stamp" "$LAB/wt/src/old.c"
[ "$EV" = none ] && touch -t "$stamp" "$ST/cx.status"
[ "$EV" = worktree ] && { touch -t "$stamp" "$ST/cx.status"; printf "recovered\n" > "$LAB/wt/src/recovered.c"; echo "== status log aged 1000s; fresh worktree write src/recovered.c"; }
echo "== evidence mode: $EV"
echo "== pane command: $(T display -p -t $W '#{pane_current_command}')"
export TMUX="$SOCK,$SPID,0"
RUN() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
echo "== real classifier verdict + endpoint liveness:"
RUN bash -c '. bin/fm-busy-lib.sh 2>/dev/null; . bin/fm-backend.sh 2>/dev/null; echo "busy=$(fm_busy_classify_meta "$FM_HOME/state/cx.meta" cx "$FM_HOME/state")"; echo "alive=$(fm_backend_agent_alive tmux lab:fm-cx)"'
WATCHENV="FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_PAUSE_RESURFACE_SECS=999"
cycle() {  # <label> <secs>
  local out="$LAB/out.$1" pid i=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" $WATCHENV bin/fm-watch.sh > "$out" 2>"$out.err" & pid=$!
  while [ $i -lt "$2" ] && kill -0 $pid 2>/dev/null; do sleep 1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then echo "[$1] watcher STILL RUNNING after ${2}s (absorbed); stdout='$(cat "$out")'"; kill $pid; wait $pid 2>/dev/null; sleep 1; kill -0 $pid 2>/dev/null && echo "[$1] WARN watcher survived kill"
  else wait $pid; echo "[$1] watcher EXITED rc=$? after ~${i}s; stdout='$(cat "$out")'"; fi
  ls "$ST"/.paused-resurfaced-* >/dev/null 2>&1 && echo "[$1] bound marker present: $(ls "$ST"/.paused-resurfaced-* | xargs -n1 basename)" || echo "[$1] no bound marker"
  RUN bin/fm-wake-drain.sh >/dev/null 2>"$LAB/drain.err"
  seq=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB/drain.err")
  [ -n "$seq" ] && RUN bin/fm-wake-drain.sh --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1 && echo "[$1] acked wake through ${seq% *}"
}
cycle warmup-status-signal 40
cycle first-stale-sight 40
echo "== codex pane re-renders (window resized: new viewport hash), endpoint still alive"
T resize-window -t $W -x 90 -y 40; [ "$EV" = dead ] && T send-keys -t $W "echo render-two" Enter; sleep 2
cycle second-stale-sight 25
echo "== codex pane re-renders again"
T resize-window -t $W -x 100 -y 40; [ "$EV" = dead ] && T send-keys -t $W "echo render-three" Enter; sleep 2
cycle third-stale-sight 25
echo "== pane after test:"; T capture-pane -p -t $W | grep -v '^\s*$' | tail -5
grep -h 'unknown\|stale' "$ST"/.triage* "$ST"/*.log 2>/dev/null | tail -5
T kill-server; rm -rf "$LAB"; echo "== lab torn down"

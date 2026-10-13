#!/usr/bin/env bash
# usage: drive.sh <bin-dir> <label> <duration-secs>
set -u
BIN=$1; LABEL=$2; DUR=$3; WT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T="tmux -L fm-lab"
FAKE='exec -a codex bash -c "i=0; while :; do i=\$((i+1)); echo long codex turn step \$i; sleep 12; done"'
$T new-session -d -s lab -n fm-prog "bash -c '$FAKE'"
$T new-window -d -t lab -n fm-noprog "bash -c '$FAKE'"
SOCK=$($T display -p '#{socket_path}')
S=$LAB/state; old=$(( $(date +%s) - 1000 )); oldstamp=$(date -r $old +%Y%m%d%H%M.%S)
for t in prog noprog; do
  mkdir -p "$LAB/wt-$t/src"; : > "$LAB/wt-$t/src/old.c"; touch -t $oldstamp "$LAB/wt-$t/src/old.c"
  printf 'window=lab:fm-%s\nkind=ship\nharness=codex\nbackend=tmux\nworktree=%s\n' $t "$LAB/wt-$t" > "$S/$t.meta"
  printf 'working: recovering source files\n' > "$S/$t.status"; touch -t $oldstamp "$S/$t.status"
done
# prog worker keeps recovering source files into its own worktree
( n=0; while [ -d "$LAB/wt-prog" ]; do n=$((n+1)); printf 'x\n' > "$LAB/wt-prog/src/recovered$n.c" 2>/dev/null; sleep 10; done ) &
WRITER=$!
echo "== $LABEL: liveness/busy probes"
( export TMUX="$SOCK,0,0" FM_HOME="$LAB"; . "$BIN/fm-backend.sh"; . "$BIN/fm-busy-lib.sh"
  for w in lab:fm-prog lab:fm-noprog; do echo "$w alive=$(fm_backend_agent_alive tmux $w) busy=$(fm_busy_classify tmux $w codex x $S)"; done )
end=$(( $(date +%s) + DUR )); cycle=0
while [ "$(date +%s)" -lt "$end" ]; do
  cycle=$((cycle+1))
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
     TMUX="$SOCK,0,0" FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
     FM_PAUSE_RESURFACE_SECS=3600 timeout $(( end - $(date +%s) + 1 )) "$BIN/fm-watch.sh" 2>/dev/null); rc=$?
  echo "$(date +%T) cycle=$cycle rc=$rc out=[$(echo "$out" | tr '\n' ' ')]"
  err=$(mktemp); FM_HOME="$LAB" "$BIN/fm-wake-drain.sh" >/dev/null 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$err"); rm -f "$err"
  [ -n "$seq" ] && FM_HOME="$LAB" "$BIN/fm-wake-drain.sh" --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1
done
echo "== $LABEL: triage log tail"; grep -h "fm-prog\|fm-noprog" "$S"/*triage* 2>/dev/null | tail -8
kill $WRITER; $T kill-server; rm -rf "$LAB"

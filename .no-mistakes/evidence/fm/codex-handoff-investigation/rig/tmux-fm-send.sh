#!/usr/bin/env bash
# Live scenario: the real bin/fm-send.sh (inbox plane) steering a task whose
# tmux worker swallows Enter. First send: rc=4 notice naming the stranded
# line. Second send: rc=1 notice (composer visibly holds pending text). Both
# exit 0 because the durable record is the delivery.
set -u
ROOT=$1; EV=$2
OUT="$EV/tmux-fm-send.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-send.XXXXXX")
SOCKET="fm-live-send-$$"; SESSION=lab; WIN=fm-t1
REAL_TMUX=$(command -v tmux)
mkdir -p "$WORK/shim" "$WORK/home/state"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; }
trap cleanup EXIT
KEYLOG="$WORK/worker.keys"; : > "$KEYLOG"
tmux new-session -d -s "$SESSION" -n "$WIN" -x 120 -y 30 -- \
  bash -c "exec -a grok python3 '$EV/rig/swallow-tui.py' '$KEYLOG'"
sleep 1
T="$SESSION:$WIN"
export FM_HOME="$WORK/home"
# The isolated temp home is a test sandbox, so the gate guard is bypassed the
# way tests/lib.sh does (documented escape hatch in bin/fm-gate-refuse-lib.sh).
export FM_GATE_REFUSE_BYPASS=1
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=grok\n' "$T" > "$FM_HOME/state/t1.meta"
say "== real bin/fm-send.sh, FM_HOME=$FM_HOME, task t1 -> $T (worker swallows Enter)"
say ""; say "### send 1 (fresh empty composer, Enter swallowed)"
rc=0; "$ROOT/bin/fm-send.sh" fm-t1 "begin validation" > "$WORK/send1.out" 2> "$WORK/send1.err" || rc=$?
say "exit=$rc"; say "-- stdout:"; cat "$WORK/send1.out" | tee -a "$OUT"; say "-- stderr:"; cat "$WORK/send1.err" | tee -a "$OUT"
say "-- pane:"; tmux capture-pane -p -t "$T" | sed -n '1,3p' | tee -a "$OUT"
say ""; say "### send 2 (our own doorbell is now stranded in the composer)"
rc2=0; "$ROOT/bin/fm-send.sh" fm-t1 "second steer" > "$WORK/send2.out" 2> "$WORK/send2.err" || rc2=$?
say "exit=$rc2"; say "-- stdout:"; cat "$WORK/send2.out" | tee -a "$OUT"; say "-- stderr:"; cat "$WORK/send2.err" | tee -a "$OUT"
say "-- inbox records:"; ls "$FM_HOME/state/t1.inbox/" | tee -a "$OUT"
say "-- keys received by worker:"; cat "$KEYLOG" | sed 's/composer=.*/composer=<doorbell line>/' | tee -a "$OUT"
RESULT=pass
[ "$rc" = 0 ] && [ "$rc2" = 0 ] || RESULT=FAIL
grep -qF 'submit did not land, so that line is stranded in the input' "$WORK/send1.err" || RESULT=FAIL
grep -qF 'doorbell skipped (composer visibly holds pending text)' "$WORK/send2.err" || RESULT=FAIL
grep -qE 'C-u|C-c|Escape|C-k|C-a|BSpace' "$KEYLOG" && RESULT=FAIL
say "RESULT: $RESULT"; [ "$RESULT" = pass ]

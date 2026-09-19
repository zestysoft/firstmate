#!/usr/bin/env bash
# Same live rig as tmux-stranded-ring.sh, but running the BASE commit's
# bin/ tree (1bb72cc5) so the original defect is reproduced: the swallowed
# submit is reported as rung (0) and the next attempt is then suppressed (1).
set -u
BASEBIN=$1; EV=$2
OUT="$EV/tmux-stranded-ring-before-fix.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-strand-base.XXXXXX")
SOCKET="fm-live-strand-base-$$"; SESSION=lab; WIN=fm-t1
REAL_TMUX=$(command -v tmux)
mkdir -p "$WORK/shim" "$WORK/state"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; }
trap cleanup EXIT
KEYLOG="$WORK/worker.keys"; : > "$KEYLOG"
tmux new-session -d -s "$SESSION" -n "$WIN" -x 120 -y 30 -- \
  bash -c "exec -a grok python3 '$EV/rig/swallow-tui.py' '$KEYLOG'"
sleep 1
T="$SESSION:$WIN"
export FM_STATE_OVERRIDE="$WORK/state"
lib() { bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$BASEBIN/bin/fm-task-inbox-lib.sh" "$@"; }
say "== BASE COMMIT 1bb72cc5 library, real tmux socket $SOCKET, target $T"
REC=$(lib fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 "begin validation")
rc=0; lib fm_task_inbox_ring tmux "$T" "$REC" "$WIN" || rc=$?
say "attempt 1 (Enter swallowed): fm_task_inbox_ring rc=$rc   <-- base commit reports RUNG (0) although the line is stranded"
say "-- pane after attempt 1:"; tmux capture-pane -p -t "$T" | sed -n '1,3p' | tee -a "$OUT"
rc2=0; lib fm_task_inbox_ring tmux "$T" "$REC" "$WIN" || rc2=$?
say "attempt 2: fm_task_inbox_ring rc=$rc2   <-- suppressed by its own doorbell; base ladder has no way to tell this from a delivered ring"
say "-- keys the worker received (base):"; grep -c 'KEY Enter' "$KEYLOG" | sed 's/^/Enter presses: /' | tee -a "$OUT"
say "RESULT: base commit reproduces the defect (rc=$rc then rc=$rc2)"

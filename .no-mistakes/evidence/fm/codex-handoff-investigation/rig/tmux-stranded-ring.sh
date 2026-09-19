#!/usr/bin/env bash
# Live scenario: real tmux (isolated socket), real firstmate inbox library,
# stand-in worker that swallows Enter. Proves rc=4 on the stranded submit,
# rc=1 on the next attempt, and that no clear/cancel key ever reaches the pane.
set -u
ROOT=$1; EV=$2
OUT="$EV/tmux-stranded-ring.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-strand.XXXXXX")
SOCKET="fm-live-strand-$$"; SESSION=lab; WIN=fm-t1
REAL_TMUX=$(command -v tmux)
mkdir -p "$WORK/shim" "$WORK/state"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; }
trap cleanup EXIT
KEYLOG="$WORK/worker.keys"; : > "$KEYLOG"
tmux new-session -d -s "$SESSION" -n "$WIN" -x 120 -y 30 -c "$ROOT" -- \
  bash -c "exec -a grok python3 '$EV/rig/swallow-tui.py' '$KEYLOG'"
sleep 1
T="$SESSION:$WIN"
export FM_STATE_OVERRIDE="$WORK/state"
lib() { bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
say "== tmux $(tmux -V | cut -d' ' -f2) isolated socket $SOCKET, target $T"
say "== pane process as seen by tmux: $(tmux display-message -p -t "$T" '#{pane_current_command}') (argv0 grok)"
say "== agent_state=$(lib fm_backend_agent_state tmux "$T")  composer_state=$(lib fm_backend_composer_state tmux "$T")"
say "== idle pane before any ring:"; tmux capture-pane -p -t "$T" | sed -n '1,3p' | tee -a "$OUT"
REC=$(lib fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 "begin validation")
say "== durable record: $REC"
say ""; say "### attempt 1: ring into an empty composer whose Enter is swallowed"
rc=0; lib fm_task_inbox_ring tmux "$T" "$REC" "$WIN" || rc=$?
say "fm_task_inbox_ring rc=$rc   (expect 4 = typed, submit provenly swallowed, line stranded)"
say "-- pane after attempt 1:"; tmux capture-pane -p -t "$T" | sed -n '1,3p' | tee -a "$OUT"
say "-- keys the worker actually received:"; cat "$KEYLOG" | tee -a "$OUT"
say "-- record still unhandled: $([ -f "$REC" ] && echo yes || echo NO)"
BEFORE=$(tmux capture-pane -p -t "$T"); KEYS_BEFORE=$(wc -l < "$KEYLOG")
say ""; say "### attempt 2: ring again while our own doorbell text is stranded"
rc2=0; lib fm_task_inbox_ring tmux "$T" "$REC" "$WIN" || rc2=$?
say "fm_task_inbox_ring rc=$rc2   (expect 1 = skipped, composer provenly holds pending text)"
AFTER=$(tmux capture-pane -p -t "$T"); KEYS_AFTER=$(wc -l < "$KEYLOG")
[ "$BEFORE" = "$AFTER" ] && say "-- pane bytes unchanged across the suppressed attempt: yes" || say "-- pane CHANGED across suppressed attempt: NO"
say "-- keystrokes received by worker during suppressed attempt: $((KEYS_AFTER - KEYS_BEFORE)) (expect 0)"
if grep -qE 'C-u|C-c|C-a|C-k|Escape|BSpace' "$KEYLOG"; then say "-- clear/cancel key seen: YES (BAD)"; else say "-- clear/cancel key seen: none"; fi
say ""; say "### adversarial: operator clears the line (SIGUSR1 to the worker), then the ring lands the doorbell again"
pkill -USR1 -f "swallow-tui.py $KEYLOG"; sleep 0.5
say "-- composer_state after operator clear: $(lib fm_backend_composer_state tmux "$T")"
rc3=0; lib fm_task_inbox_ring tmux "$T" "$REC" "$WIN" || rc3=$?
say "fm_task_inbox_ring rc=$rc3   (expect 4 again: typed fresh, Enter still swallowed by this worker)"
say "-- final key log:"; cat "$KEYLOG" | tee -a "$OUT"
RESULT=pass
[ "$rc" = 4 ] && [ "$rc2" = 1 ] && [ "$BEFORE" = "$AFTER" ] && [ "$((KEYS_AFTER - KEYS_BEFORE))" = 0 ] && [ "$rc3" = 4 ] || RESULT=FAIL
say ""; say "RESULT: $RESULT"
[ "$RESULT" = pass ]

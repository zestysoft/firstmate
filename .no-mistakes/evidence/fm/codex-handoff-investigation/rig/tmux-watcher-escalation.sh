#!/usr/bin/env bash
# Live scenario: the real bin/fm-watch.sh subprocess against a real tmux pane
# whose worker swallows Enter. With a ring budget of 1 the ladder must escalate
# ONCE as a stranded-input wake (not "inspect the worker"), hand over the
# fm-send delivery path, and go quiet afterwards.
# Only the crew-state probe (bin/fm-crew-state.sh, unrelated to this change) is
# answered by a stub, exactly as tests/wake-helpers.sh does.
set -u
ROOT=$1; EV=$2
OUT="$EV/tmux-watcher-escalation.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-watch.XXXXXX")
SOCKET="fm-live-watch-$$"; SESSION=lab; WIN=fm-t1
REAL_TMUX=$(command -v tmux)
mkdir -p "$WORK/shim" "$WORK/state"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
cat > "$WORK/shim/fm-crew-state.sh" <<'CS'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
CS
chmod +x "$WORK/shim/fm-crew-state.sh"
export PATH="$WORK/shim:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; }
trap cleanup EXIT
KEYLOG="$WORK/worker.keys"; : > "$KEYLOG"
tmux new-session -d -s "$SESSION" -n "$WIN" -x 120 -y 30 -- \
  bash -c "exec -a grok python3 '$EV/rig/swallow-tui.py' '$KEYLOG'"
sleep 1
T="$SESSION:$WIN"
STATE="$WORK/state"
printf 'window=%s\nkind=ship\nharness=grok\n' "$T" > "$STATE/t1.meta"
lib() { FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
REC=$(lib fm_task_inbox_write "$STATE" t1 "begin validation")
touch -t 202001010000 "$REC"
say "== real fm-watch.sh, real tmux socket $SOCKET, stranded worker at $T, record $REC, FM_TASK_INBOX_RING_MAX=1"
FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$WORK/shim/fm-crew-state.sh" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=1 \
  "$ROOT/bin/fm-watch.sh" > "$WORK/watch.out" 2> "$WORK/watch.err" &
PID=$!
i=0; while [ "$i" -lt 600 ] && kill -0 "$PID" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
if kill -0 "$PID" 2>/dev/null; then say "watcher still running after 60s"; kill "$PID"; fi
say "-- watcher stdout:"; cat "$WORK/watch.out" | tee -a "$OUT"
say "-- pane after the watcher's single ring attempt:"; tmux capture-pane -p -t "$T" | sed -n '1,3p' | tee -a "$OUT"
say "-- keys received by worker:"; grep -c 'KEY Enter' "$KEYLOG" | sed 's/^/Enter presses: /' | tee -a "$OUT"; grep -E 'C-u|C-c|Escape|C-k|C-a|BSpace' "$KEYLOG" | tee -a "$OUT" || say "no clear/cancel keys"
say "-- .ring-state (msg, count, epoch, input-blocked streak):"; cat "$STATE/t1.inbox/.ring-state" | tee -a "$OUT"
say "-- .wake-queue:"; cat "$STATE/.wake-queue" | tee -a "$OUT"
say "-- escalations queued: $(grep -cF 'unread firstmate instruction' "$STATE/.wake-queue")"
say "-- next due_action for the record: $(lib fm_task_inbox_due_action "$STATE" t1)"
RESULT=pass
grep -qF 'input line holds unsubmitted text' "$STATE/.wake-queue" || RESULT=FAIL
grep -qF 'the worker is not the blocker' "$STATE/.wake-queue" || RESULT=FAIL
grep -qF 'will not ring this record again' "$STATE/.wake-queue" || RESULT=FAIL
grep -qF 'bin/fm-send.sh' "$STATE/.wake-queue" || RESULT=FAIL
grep -qF 'inspect the worker' "$STATE/.wake-queue" && RESULT=FAIL
[ "$(grep -cF 'unread firstmate instruction' "$STATE/.wake-queue")" = 1 ] || RESULT=FAIL
[ "$(lib fm_task_inbox_due_action "$STATE" t1)" = quiet ] || RESULT=FAIL
grep -qE 'C-u|C-c|Escape|C-k|C-a|BSpace' "$KEYLOG" && RESULT=FAIL
say "RESULT: $RESULT"; [ "$RESULT" = pass ]

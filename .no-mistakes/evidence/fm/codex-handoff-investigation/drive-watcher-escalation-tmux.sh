#!/usr/bin/env bash
# Live driver: the REAL bin/fm-watch.sh process, re-ringing a REAL tmux pane
# until its ladder budget is spent, and what it then tells the reader.
#
#   1. swallow pane -> every attempt is suppressed by an unsubmitted input line,
#                      so the escalation must name that line, say the worker is
#                      NOT the blocker, hand over a delivery path of its own,
#                      and admit it will not ring again.
#   2. submit pane  -> the doorbell lands every time and the worker simply never
#                      acknowledges, so the SAME ladder must still escalate with
#                      the ordinary "inspect the worker" wording. This is the
#                      adversarial half: the new branch must not swallow the old
#                      case whole.
set -u
ROOT=$1
EV=$2
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-strand.XXXXXX")
LAB=$(cd "$LAB" && pwd)
FAILED=0
SOCKET=""

cleanup() {
  [ -z "$SOCKET" ] || "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

say() { printf '\n==== %s ====\n' "$1"; }
check() { if [ "$3" = 0 ]; then printf 'PASS - %s\n' "$1"; else printf 'FAIL - %s (%s)\n' "$1" "$2"; FAILED=1; fi; }

# One case = one private tmux server, one real pane process, one real watcher.
run_case() {  # <mode> -> echoes the state dir
  local mode=$1 dir fb i
  dir="$LAB/$mode"
  SOCKET="fm-watch-strand-$mode-$$"
  fb="$dir/fakebin"
  mkdir -p "$dir/state" "$fb"
  # The only tmux "stub" is a shim pinning the REAL tmux to a private server.
  cat > "$fb/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
  chmod +x "$fb/tmux"
  # The watcher's crew-state reader is stubbed: it reports an unrelated fleet
  # subsystem and is not part of the steering decision under test.
  cat > "$fb/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
EOF
  chmod +x "$fb/fm-crew-state.sh"

  printf 'window=%s:fm-t1\nkind=ship\nharness=codex\n' "watchlab" > "$dir/state/t1.meta"

  "$REAL_TMUX" -L "$SOCKET" new-session -d -s watchlab -n fm-t1 -x 200 -y 40 -c "$ROOT"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t watchlab:fm-t1 \
    "clear; AGENT_MODE=$mode exec python3 '$EV/composer-pane-agent.py'" Enter
  sleep 2

  REC=$(env FM_STATE_OVERRIDE="$dir/state" bash -c \
    '. "$1"/bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$2" t1 "please rebase onto main"' \
    _ "$ROOT" "$dir/state")
  touch -t 202001010000 "$REC"

  env PATH="$fb:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_GATE_REFUSE_BYPASS=1 \
    FM_CREW_STATE_BIN="$fb/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=2 \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>"$dir/watch.err" &
  local pid=$!
  i=0
  while [ "$i" -lt 400 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t watchlab:fm-t1 > "$EV/watcher-pane-$mode.txt" 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  SOCKET=""
  printf '%s\n' "$dir/state"
}

say "scenario 1: the ladder spends its whole budget on an unsubmitted input line"
S1=$(run_case swallow)
printf -- '--- wake queued by the real watcher ---\n'
sed -e 's/^/  /' "$S1/.wake-queue" 2>/dev/null || echo "  (no wake queued)"
cp "$S1/.wake-queue" "$EV/watcher-wake-swallow.txt" 2>/dev/null || true
grep -q "input line holds unsubmitted text" "$S1/.wake-queue" 2>/dev/null; check \
  "the escalation names the unsubmitted input line" "wording missing" $?
grep -q "the worker is not the blocker" "$S1/.wake-queue" 2>/dev/null; check \
  "the escalation says the worker is not the blocker" "wording missing" $?
grep -q "bin/fm-send.sh" "$S1/.wake-queue" 2>/dev/null; check \
  "the escalation hands over a delivery path of its own" "no delivery path offered" $?
grep -q "will not ring this record again" "$S1/.wake-queue" 2>/dev/null; check \
  "the escalation admits no further automatic ring will land" "false promise of a re-ring" $?
! grep -q "inspect the worker" "$S1/.wake-queue" 2>/dev/null; check \
  "the escalation does NOT send the reader to inspect the worker" "inverted blame" $?
[ "$(grep -c 'unread firstmate instruction' "$S1/.wake-queue" 2>/dev/null || echo 0)" = 1 ]; check \
  "exactly one wake is surfaced, not a repeating blocked path" "wake count wrong" $?
grep -q 'Firstmate instruction waiting' "$EV/watcher-pane-swallow.txt"; check \
  "the stranded doorbell is still visibly sitting in the real composer" "not on screen" $?

say "scenario 2 (adversarial): a landed doorbell an idle worker never acknowledges"
S2=$(run_case submit)
printf -- '--- wake queued by the real watcher ---\n'
sed -e 's/^/  /' "$S2/.wake-queue" 2>/dev/null || echo "  (no wake queued)"
cp "$S2/.wake-queue" "$EV/watcher-wake-submit.txt" 2>/dev/null || true
grep -q "inspect the worker" "$S2/.wake-queue" 2>/dev/null; check \
  "a landed-but-unacknowledged steer still escalates against the worker" "wording missing" $?
! grep -q "input line holds unsubmitted text" "$S2/.wake-queue" 2>/dev/null; check \
  "the new stranded-input branch does NOT swallow the ordinary case" "over-broad branch" $?
grep -q 'Firstmate instruction waiting' "$EV/watcher-pane-submit.txt"; check \
  "the doorbell really was submitted into the transcript each time" "doorbell never landed" $?

printf '\n==== result: %s ====\n' "$([ "$FAILED" = 0 ] && echo ALL-PASS || echo FAILURES)"
exit "$FAILED"

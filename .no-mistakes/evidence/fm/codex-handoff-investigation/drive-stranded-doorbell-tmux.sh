#!/usr/bin/env bash
# Live driver: the real bin/fm-send.sh steering CLI against a REAL tmux pane
# running a REAL interactive composer process, on a private tmux server.
#
#   1. swallow pane  -> the doorbell's Enter is eaten, the line is stranded in
#                       the composer, and fm-send must SAY SO (ring rc=4).
#   2. same pane     -> the next send is suppressed to protect that line (rc=1)
#                       and nothing is typed, cleared, or submitted.
#   3. submit pane   -> an Enter that lands must report a plain delivery, with
#                       no stranded-input claim at all.
set -u
# This driver never touches the real fleet: a private tmux server socket and a
# private FM_HOME/state tree, the same isolation tests/fm-send-inbox-doorbell-
# live-e2e.test.sh uses. FM_GATE_REFUSE_BYPASS is firstmate's own documented
# test-harness hatch (bin/fm-gate-refuse-lib.sh), exported by tests/lib.sh for
# every test that drives the real fm-send against a temp-sandbox fleet.
export FM_GATE_REFUSE_BYPASS=1
ROOT=$1
EV=$2
SOCKET="fm-strand-live-$$"
SESSION="strandlab"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-strand-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
REAL_TMUX=$(command -v tmux)
FAILED=0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/home/state"
cat > "$LAB/shim/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"

printf 'window=%s:fm-t1\nkind=ship\nharness=codex\n' "$SESSION" > "$LAB/home/state/t1.meta"

say() { printf '\n==== %s ====\n' "$1"; }
check() {  # <label> <condition-desc> <0|1 ok>
  if [ "$3" = 0 ]; then printf 'PASS - %s\n' "$1"; else printf 'FAIL - %s (%s)\n' "$1" "$2"; FAILED=1; fi
}

start_pane() {  # <mode>
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" -n fm-t1 -x 200 -y 40 -c "$ROOT"
  tmux send-keys -t "$SESSION:fm-t1" \
    "clear; AGENT_MODE=$1 exec python3 '$EV/composer-pane-agent.py'" Enter
  sleep 2
}

shot() {  # <file>
  tmux capture-pane -p -t "$SESSION:fm-t1" > "$EV/$1"
}

send() {  # <msg> <errfile>
  env FM_ROOT_OVERRIDE="$LAB/home" FM_HOME="$LAB/home" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 "$1" >/dev/null 2>"$LAB/$2"
}

say "scenario 1: a real pane that swallows Enter"
start_pane swallow
shot pane-01-swallow-before-send.txt
send "please rebase onto main and report back" err1
printf -- '--- fm-send operator output ---\n'; cat "$LAB/err1"
shot pane-02-swallow-doorbell-stranded.txt
grep -q 'stranded in the input' "$LAB/err1"; check \
  "fm-send reports the doorbell as stranded in the input line" "no stranded notice" $?
[ -f "$LAB/home/state/t1.inbox/001.msg" ]; check \
  "the steer itself is still durably recorded" "record missing" $?
grep -q 'Firstmate instruction waiting' "$EV/pane-02-swallow-doorbell-stranded.txt"; check \
  "the doorbell text is visibly sitting in the composer box" "doorbell not on screen" $?

say "scenario 2: the next send must protect that stranded line"
before=$(cat "$EV/pane-02-swallow-doorbell-stranded.txt")
send "and also update the changelog" err2
printf -- '--- fm-send operator output ---\n'; cat "$LAB/err2"
shot pane-03-swallow-second-send-suppressed.txt
after=$(cat "$EV/pane-03-swallow-second-send-suppressed.txt")
grep -q 'composer visibly holds pending text' "$LAB/err2"; check \
  "the second send is suppressed to protect the pending line" "not suppressed" $?
[ -f "$LAB/home/state/t1.inbox/002.msg" ]; check \
  "the suppressed send is still durably recorded" "record missing" $?
[ "$before" = "$after" ]; check \
  "the pane is byte-identical: nothing typed, cleared, or submitted" "pane changed" $?

say "scenario 3: a real pane whose Enter lands"
start_pane submit
rm -rf "$LAB/home/state/t1.inbox"
send "run the smoke test" err3
printf -- '--- fm-send operator output ---\n'; cat "$LAB/err3"; printf '(no output above means a clean delivery)\n'
sleep 1
shot pane-04-submit-doorbell-delivered.txt
! grep -q 'stranded in the input' "$LAB/err3"; check \
  "a landed submit is NEVER reported as stranded" "false stranded claim" $?
! grep -q 'doorbell' "$LAB/err3"; check \
  "a landed submit produces no delivery notice at all" "unexpected notice" $?
grep -q 'Firstmate instruction waiting' "$EV/pane-04-submit-doorbell-delivered.txt"; check \
  "the doorbell was submitted into the transcript" "doorbell not submitted" $?
env FM_GATE_REFUSE_BYPASS=1 bash -c \
  '. "$1"/bin/fm-backend.sh; [ "$(fm_backend_composer_state tmux "$2" fm-t1)" = empty ]' \
  _ "$ROOT" "$SESSION:fm-t1"; check \
  "the real composer classifier reads the input line empty again after the submit" \
  "composer still holds text" $?

printf '\n==== result: %s ====\n' "$([ "$FAILED" = 0 ] && echo ALL-PASS || echo FAILURES)"
exit "$FAILED"

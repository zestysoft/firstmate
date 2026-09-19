#!/usr/bin/env bash
# Live scenario: REAL codex-cli in an isolated tmux server, steered through the
# REAL bin/fm-send.sh inbox plane. Proves the doorbell lands (no stranded-line
# notice), the composer clears, and codex acts on and acknowledges the record.
# Codex runs with a temporary CODEX_HOME (auth symlinked, only the temp cwd
# trusted) so the operator's ~/.codex config is never modified.
set -u
ROOT=$1; EV=$2
OUT="$EV/tmux-codex-handoff.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-codex.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
SOCKET="fm-live-codex-$$"; SESSION=lab; WIN=fm-codex
REAL_TMUX=$(command -v tmux)
mkdir -p "$WORK/shim" "$WORK/home/state" "$WORK/cwd" "$WORK/codex-home"
ln -s ~/.codex/auth.json "$WORK/codex-home/auth.json"
printf 'model = "gpt-6-astra"\n[projects."%s"]\ntrust_level = "trusted"\n' "$WORK/cwd" > "$WORK/codex-home/config.toml"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$WORK/codex-home"; }
trap cleanup EXIT
tmux new-session -d -s "$SESSION" -n "$WIN" -x 140 -y 40 -c "$WORK/cwd" -- \
  env CODEX_HOME="$WORK/codex-home" codex --dangerously-bypass-approvals-and-sandbox
T="$SESSION:$WIN"
lib() { FM_STATE_OVERRIDE="$WORK/home/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
say "== real $(codex --version) in real tmux $(tmux -V | cut -d' ' -f2), isolated socket $SOCKET, target $T"
i=0; v=''; dismissed=0
while [ "$i" -lt 60 ]; do
  v=$(lib fm_backend_composer_state tmux "$T"); [ "$v" = empty ] && break
  i=$((i+1))
  if [ "$dismissed" = 0 ] && [ "$i" -ge 20 ]; then
    tmux capture-pane -p -t "$T" | grep -qi trust || tmux send-keys -t "$T" Escape; dismissed=1
  fi
  sleep 1
done
say "== composer_state after ${i}s: $v   agent_state=$(lib fm_backend_agent_state tmux "$T")"
say "-- idle codex screen (tail):"; tmux capture-pane -p -t "$T" | grep -v '^\s*$' | tail -6 | tee -a "$OUT"
export FM_HOME="$WORK/home" FM_GATE_REFUSE_BYPASS=1
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=codex\n' "$T" > "$FM_HOME/state/t1.meta"
ACTED="$WORK/acted"
say ""; say "### real fm-send.sh steer into idle codex"
rc=0; "$ROOT/bin/fm-send.sh" fm-t1 "Firstmate live check: run exactly this shell command now: touch $ACTED - then follow the mv instruction you were given for this message. Reply with one short line." > "$WORK/send.out" 2> "$WORK/send.err" || rc=$?
say "exit=$rc"; say "-- stderr (fm-send lines only):"; grep '^fm-send' "$WORK/send.err" | tee -a "$OUT" || say "(no fm-send notice: doorbell rc=0, i.e. typed and submit landed)"
REC="$FM_HOME/state/t1.inbox/001.msg"
sleep 2
say "-- screen right after the doorbell:"; tmux capture-pane -p -t "$T" | grep -v '^\s*$' | tail -8 | tee -a "$OUT"
say "-- composer_state right after the doorbell: $(lib fm_backend_composer_state tmux "$T")"
i=0; while [ "$i" -lt 180 ]; do [ -f "$FM_HOME/state/t1.inbox/handled/001.msg" ] && [ -e "$ACTED" ] && break; sleep 1; i=$((i+1)); done
say ""; say "== after ${i}s: acted=$([ -e "$ACTED" ] && echo yes || echo no) acked(handled/001.msg)=$([ -f "$FM_HOME/state/t1.inbox/handled/001.msg" ] && echo yes || echo no)"
say "-- final codex screen (tail):"; tmux capture-pane -p -t "$T" | grep -v '^\s*$' | tail -14 | tee -a "$OUT"
tmux capture-pane -p -t "$T" -S -200 > "$EV/tmux-codex-handoff.final-screen.txt"
RESULT=pass
[ "$rc" = 0 ] || RESULT=FAIL
grep -q 'stranded\|doorbell skipped\|did not reach\|not typed' "$WORK/send.err" && RESULT=FAIL
[ -e "$ACTED" ] && [ -f "$FM_HOME/state/t1.inbox/handled/001.msg" ] || RESULT=FAIL
say "RESULT: $RESULT"; [ "$RESULT" = pass ]

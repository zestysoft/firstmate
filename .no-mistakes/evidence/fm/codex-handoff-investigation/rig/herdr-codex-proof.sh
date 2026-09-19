#!/usr/bin/env bash
# Live scenario: REAL codex-cli in an isolated herdr lab session (the fleet's
# Codex-on-herdr case). Drives the real herdr adapter and the real inbox ring:
#   - a pane with no registered agent: fm_backend_submit_pending_is_proof -> 1
#   - an idle codex pane (native agent_status idle): proof -> 0
#   - a real doorbell ring lands (rc 0); read immediately after the submit the
#     pane is `working`, and the proof predicate answers 1 there (post-submit
#     working = the Enter LANDED, never a swallow)
#   - codex acts on and acknowledges the record; back at idle the proof is 0
# Codex runs with a temp CODEX_HOME (auth + herdr hook files symlinked, only
# the temp cwd trusted) so ~/.codex is never modified.
set -u
ROOT=$1; EV=$2
OUT="$EV/herdr-codex-proof.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB="$ROOT/bin/fm-herdr-lab.sh"; ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name codexproof)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-herdr.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
mkdir -p "$WORK/fakebin" "$WORK/state" "$WORK/codex-home" "$WORK/cwd"
CWD="$WORK/cwd"
cat > "$WORK/fakebin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$WORK/fakebin/herdr"
lab() { env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "$@"; }
cleanup() { PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" >/dev/null 2>&1 || say "!! lab teardown reported a problem"; rm -rf "$WORK/codex-home"; }
trap cleanup EXIT
"$LAB" provision "$SESSION" || { say "provision failed"; exit 1; }
WS=$(lab workspace create --cwd "$CWD" --label fm-codexproof --no-focus); PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
ln -s ~/.codex/auth.json "$WORK/codex-home/auth.json"
ln -s ~/.codex/hooks.json "$WORK/codex-home/hooks.json"
ln -s ~/.codex/herdr-agent-state.sh "$WORK/codex-home/herdr-agent-state.sh"
printf 'model = "gpt-6-astra"\n[projects."%s"]\ntrust_level = "trusted"\n' "$CWD" > "$WORK/codex-home/config.toml"
export PATH="$WORK/fakebin:$ORIGINAL_PATH"
T="$SESSION:$PANE"
lib() { FM_STATE_OVERRIDE="$WORK/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
raw() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
proof() { local r=0; lib fm_backend_submit_pending_is_proof herdr "$T" || r=$?; printf '%s' "$r"; }
say "== $(herdr --version 2>/dev/null | head -1 || env PATH="$ORIGINAL_PATH" herdr --version | head -1) lab session $SESSION, pane $PANE, target $T"
say ""; say "### 1. pane with NO registered agent (bare shell): agent get -> $(lab agent get "$PANE" 2>&1 | jq -c '.error.code // .result.agent.agent_status')"
p0=$(proof); say "fm_backend_submit_pending_is_proof herdr $T -> rc=$p0   (expect 1: unreadable native status is never proof)"
say ""; say "### 2. launch real $(codex --version) in the herdr pane"
lab pane run "$PANE" "CODEX_HOME='$WORK/codex-home' codex --dangerously-bypass-approvals-and-sandbox" >/dev/null || say "!! pane run failed"
sleep 10
if lab pane read "$PANE" --source visible 2>/dev/null | grep -q 'Hooks need review'; then
  say "-- codex hooks-review dialog in the temp home: selecting 'Trust all and continue' (temp CODEX_HOME only)"
  lab pane send-text "$PANE" "2" >/dev/null; sleep 0.5; lab pane send-keys "$PANE" enter >/dev/null
fi
i=0; st=''; ok=0; while [ "$i" -lt 90 ]; do st=$(raw); case "$st" in idle|done) ok=$((ok+1));; *) ok=0;; esac; [ "$ok" -ge 3 ] && break; sleep 1; i=$((i+1)); done
say "-- settled: native status stayed idle for 3 consecutive 1s reads"
say "-- native agent_status after ${i}s: '$st'   adapter agent_state=$(lib fm_backend_agent_state herdr "$T")   composer_state=$(lib fm_backend_composer_state herdr "$T")"
say "-- idle codex pane (visible tail):"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | tail -4 | tee -a "$OUT"
p1=$(proof); say "fm_backend_submit_pending_is_proof herdr $T -> rc=$p1   (expect 0: legibly idle pane, a surviving pending WOULD be proof here)"
say ""; say "### 3. real doorbell ring into idle codex on herdr"
ACTED="$WORK/acted"
REC=$(lib fm_task_inbox_write "$WORK/state" t1 "Firstmate live check: run exactly this shell command now: touch $ACTED - then follow the mv instruction you were given for this message. Reply with one short line.")
rc=0; lib fm_task_inbox_ring herdr "$T" "$REC" || rc=$?
st_after=$(raw); p2=$(proof)
say "fm_task_inbox_ring herdr rc=$rc   (expect 0: typed and submit landed, NOT 4)"
say "-- native agent_status read immediately AFTER the submit: '$st_after'"
say "fm_backend_submit_pending_is_proof herdr $T (post-submit) -> rc=$p2   (expect 1 when '$st_after' is working: a working pane after the submit means the Enter landed)"
say "-- pane right after the doorbell (visible tail):"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | tail -6 | tee -a "$OUT"
i=0; while [ "$i" -lt 180 ]; do [ -f "$WORK/state/t1.inbox/handled/${REC##*/}" ] && [ -e "$ACTED" ] && break; sleep 1; i=$((i+1)); done
say ""; say "== after ${i}s: acted=$([ -e "$ACTED" ] && echo yes || echo no) acked=$([ -f "$WORK/state/t1.inbox/handled/${REC##*/}" ] && echo yes || echo no)"
i=0; st_end=''; while [ "$i" -lt 90 ]; do st_end=$(raw); case "$st_end" in idle|done) break;; esac; sleep 1; i=$((i+1)); done
p3=$(proof); say "-- native agent_status once the turn ended: '$st_end'; proof -> rc=$p3 (expect 0 again)"
say "-- final pane (visible tail):"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | tail -10 | tee -a "$OUT"
lab pane read "$PANE" --source recent --lines 200 > "$EV/herdr-codex-proof.final-screen.txt" 2>/dev/null || true
RESULT=pass
[ "$p0" = 1 ] || RESULT=FAIL
[ "$p1" = 0 ] || RESULT=FAIL
[ "$rc" = 0 ] || RESULT=FAIL
if [ "$st_after" = working ]; then [ "$p2" = 1 ] || RESULT=FAIL; else say "!! post-submit status was '$st_after', not working; the working-branch check could not be observed on this run"; RESULT=INCONCLUSIVE-WORKING; fi
[ -e "$ACTED" ] && [ -f "$WORK/state/t1.inbox/handled/${REC##*/}" ] || RESULT=FAIL
[ "$p3" = 0 ] || RESULT=FAIL
say ""; say "RESULT: $RESULT"; [ "$RESULT" = pass ]

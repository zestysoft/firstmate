#!/usr/bin/env bash
# Live scenario on a REAL herdr lab pane: the stand-in worker (a harness-named
# process registered through herdr's own `pane report-agent`) swallows Enter.
#   A. registered idle  -> ring reports 4 (stranded), next ring 1, no clear keys
#   B. registered blocked (Cursor-shaped) -> the same swallowed submit stays
#      advisory (0), never a stranded-line claim
set -u
ROOT=$1; EV=$2
OUT="$EV/herdr-stranded-ring.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB="$ROOT/bin/fm-herdr-lab.sh"; ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name strand)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-herdr-strand.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
mkdir -p "$WORK/fakebin" "$WORK/state" "$WORK/cwd" "$WORK/bin"
ln -s "$(command -v python3)" "$WORK/bin/grok"
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
cleanup() { PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" >/dev/null 2>&1 || say "!! lab teardown problem"; }
trap cleanup EXIT
"$LAB" provision "$SESSION" || { say "provision failed"; exit 1; }
WS=$(lab workspace create --cwd "$WORK/cwd" --label fm-strand --no-focus); PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
T="$SESSION:$PANE"
export PATH="$WORK/fakebin:$ORIGINAL_PATH"
lib() { FM_STATE_OVERRIDE="$WORK/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
raw() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "<none>"'; }
KEYLOG="$WORK/worker.keys"; : > "$KEYLOG"
lab pane run "$PANE" "exec '$WORK/bin/grok' '$EV/rig/swallow-tui.py' '$KEYLOG'" >/dev/null
sleep 2
lab pane report-agent "$PANE" --source fm-live-test --agent codex-standin --state idle >/dev/null || say "!! report-agent failed"
sleep 1
say "== herdr lab $SESSION pane $PANE; stand-in worker process: $(lab pane process-info "$PANE" 2>/dev/null | jq -c '.result | {foreground_command: (.foreground_command // .foreground // .process // .)}' | head -c 200)"
say "== native agent_status=$(raw)  adapter agent_state=$(lib fm_backend_agent_state herdr "$T")  composer_state=$(lib fm_backend_composer_state herdr "$T")"
say "-- idle pane:"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | head -3 | tee -a "$OUT"
REC=$(lib fm_task_inbox_write "$WORK/state" t1 "begin validation")
say ""; say "### A1. ring into an idle-registered herdr pane whose Enter is swallowed"
rc=0; lib fm_task_inbox_ring herdr "$T" "$REC" || rc=$?
say "fm_task_inbox_ring herdr rc=$rc   (expect 4)"
say "-- pane:"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | head -3 | tee -a "$OUT"
say "-- Enter presses received by worker: $(grep -c 'KEY Enter' "$KEYLOG")"
BEFORE=$(lab pane read "$PANE" --source visible); KB=$(wc -l < "$KEYLOG")
say ""; say "### A2. ring again while our doorbell is stranded"
rc2=0; lib fm_task_inbox_ring herdr "$T" "$REC" || rc2=$?
say "fm_task_inbox_ring herdr rc=$rc2   (expect 1)"
AFTER=$(lab pane read "$PANE" --source visible); KA=$(wc -l < "$KEYLOG")
say "-- pane unchanged: $([ "$BEFORE" = "$AFTER" ] && echo yes || echo NO); keys sent during suppressed attempt: $((KA-KB)) (expect 0)"
say ""; say "### B. same pane registered 'blocked' (Cursor reads blocked in every state): operator clears the line, ring again"
lab pane report-agent "$PANE" --source fm-live-test --agent codex-standin --state blocked >/dev/null || say "!! report-agent blocked failed"
pkill -USR1 -f "swallow-tui.py $KEYLOG"; sleep 1
say "-- native agent_status=$(raw)  composer_state after clear=$(lib fm_backend_composer_state herdr "$T")"
rc3=0; lib fm_task_inbox_ring herdr "$T" "$REC" || rc3=$?
say "fm_task_inbox_ring herdr rc=$rc3   (expect 0: a blocked pane cannot prove a swallow, so pending stays advisory)"
say "-- pane after B (doorbell typed, still stranded, but NOT claimed as stranded):"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | head -3 | tee -a "$OUT"
say "-- full key log:"; sed 's/composer=.*/composer=<doorbell line>/' "$KEYLOG" | tee -a "$OUT"
RESULT=pass
[ "$rc" = 4 ] && [ "$rc2" = 1 ] && [ "$BEFORE" = "$AFTER" ] && [ "$((KA-KB))" = 0 ] && [ "$rc3" = 0 ] || RESULT=FAIL
grep -qE 'C-u|C-c|Escape|C-k|C-a|BSpace' "$KEYLOG" && RESULT=FAIL
say ""; say "RESULT: $RESULT"; [ "$RESULT" = pass ]

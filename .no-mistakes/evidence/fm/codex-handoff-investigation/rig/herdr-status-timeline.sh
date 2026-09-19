#!/usr/bin/env bash
# Diagnostic: sample herdr's native agent_status and the per-pane proof
# predicate together every 0.5s while a real codex starts up idle, to see
# whether the two ever disagree at the same instant.
set -u
ROOT=$1; EV=$2
OUT="$EV/herdr-status-timeline.transcript.txt"; : > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB="$ROOT/bin/fm-herdr-lab.sh"; ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name codextl)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-herdr-tl.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
mkdir -p "$WORK/fakebin" "$WORK/state" "$WORK/codex-home" "$WORK/cwd"
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
cleanup() { PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" >/dev/null 2>&1 || say "!! lab teardown problem"; rm -rf "$WORK/codex-home"; }
trap cleanup EXIT
"$LAB" provision "$SESSION" || { say "provision failed"; exit 1; }
WS=$(lab workspace create --cwd "$WORK/cwd" --label fm-tl --no-focus); PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
T="$SESSION:$PANE"
ln -s ~/.codex/auth.json "$WORK/codex-home/auth.json"; ln -s ~/.codex/hooks.json "$WORK/codex-home/hooks.json"; ln -s ~/.codex/herdr-agent-state.sh "$WORK/codex-home/herdr-agent-state.sh"
printf 'model = "gpt-6-astra"\n[projects."%s"]\ntrust_level = "trusted"\n' "$WORK/cwd" > "$WORK/codex-home/config.toml"
export PATH="$WORK/fakebin:$ORIGINAL_PATH"
lib() { FM_STATE_OVERRIDE="$WORK/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
raw() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "<none>"'; }
adapter_raw() { lib fm_backend_herdr_agent_status_raw "$SESSION" "$PANE"; }
proof() { local r=0; lib fm_backend_submit_pending_is_proof herdr "$T" || r=$?; printf '%s' "$r"; }
say "== lab $SESSION pane $PANE: launching codex, then sampling"
lab pane run "$PANE" "CODEX_HOME='$WORK/codex-home' codex --dangerously-bypass-approvals-and-sandbox" >/dev/null
sleep 8
if lab pane read "$PANE" --source visible 2>/dev/null | grep -q 'Hooks need review'; then
  lab pane send-text "$PANE" "2" >/dev/null; sleep 0.5; lab pane send-keys "$PANE" enter >/dev/null; say "-- hooks dialog accepted (temp home)"
fi
say "t(s)  native_status  adapter_status_raw  proof_rc"
start=$(date +%s)
for i in $(seq 1 60); do
  a=$(raw); b=$(adapter_raw); p=$(proof)
  say "$(( $(date +%s) - start ))     $a     $b     $p"
  sleep 0.5
done
say "-- screen tail:"; lab pane read "$PANE" --source visible | grep -v '^\s*$' | tail -4 | tee -a "$OUT"

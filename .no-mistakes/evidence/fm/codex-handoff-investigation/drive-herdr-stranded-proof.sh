#!/usr/bin/env bash
# Live driver for the change under test: whether a `pending` post-submit verdict
# on a REAL herdr pane running a REAL Codex worker is treated as PROOF that the
# Enter was swallowed.
#
#   1. idle Codex pane    -> pending IS proof (herdr keeps the per-pane proof,
#                            which is where the stalled handoff was observed).
#   2. working Codex pane -> pending is NOT proof, because this read happens
#                            AFTER the submit, so `working` means the Enter
#                            LANDED. The pre-fix adapter is run against the very
#                            same live pane to show it answered the opposite.
#   3. the same two states through the real fm_task_inbox_ring: rc=4 (stranded)
#                            when idle, rc=0 (advisory) when working.
#
# Everything herdr-side is routed through bin/fm-herdr-lab.sh, so the real
# default fleet session is never touched.
set -u
ROOT=$1
EV=$2
OLD_REF=${3:-870079a}

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name strandproof)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-strandproof.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN" "$TMP_ROOT/state"
FAILED=0

cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer stop "$SESSION" >/dev/null 2>&1 || true
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

say() { printf '\n==== %s ====\n' "$1"; }
check() { if [ "$3" = 0 ]; then printf 'PASS - %s\n' "$1"; else printf 'FAIL - %s (%s)\n' "$1" "$2"; FAILED=1; fi; }

"$LAB_HELPER" provision "$SESSION" || { echo "could not provision the isolated herdr lab" >&2; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

# A real foreground herdr client over a fixed 40x120 pty: a headless lab pane is
# otherwise too narrow for a real Codex TUI to render its composer.
env PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer start "$SESSION" \
  || { echo "could not attach the lab viewer" >&2; exit 1; }

# Codex runs in a scratch cwd, not the worktree: a project with hooks parks Codex
# on its hook-review dialog, which is a genuinely unready endpoint and not the
# state under test here. The pane still runs the real Codex binary on real herdr.
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"
WS_JSON=$(lab workspace create --cwd "$SCRATCH" --label fm-strandproof --no-focus)
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
CODEX_VER=$(PATH="$ORIGINAL_PATH" codex --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
printf 'lab session %s, pane %s, %s on %s\n' "$SESSION" "$PANE" "$CODEX_VER" "$HERDR_VER"

# Codex is given an ISOLATED CODEX_HOME so this run never edits the operator's
# real ~/.codex config: its own auth copy plus a pre-trusted entry for this
# worktree, which is what keeps the pane off codex's trust dialog (a pane parked
# on that dialog reads `blocked` forever and is a genuinely unready endpoint).
CODEX_HOME_LAB="$TMP_ROOT/codex-home"
mkdir -p "$CODEX_HOME_LAB"
cp "$HOME/.codex/auth.json" "$CODEX_HOME_LAB/auth.json" \
  || { echo "could not copy codex credentials into the isolated CODEX_HOME" >&2; exit 1; }
{
  printf 'model = "gpt-6-astra"\n'
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$SCRATCH"
} > "$CODEX_HOME_LAB/config.toml"

lab pane run "$PANE" "cd '$SCRATCH' && CODEX_HOME='$CODEX_HOME_LAB' exec codex --dangerously-bypass-approvals-and-sandbox" >/dev/null \
  || { echo "could not launch codex in the lab pane" >&2; exit 1; }

status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

wait_status() {  # <regex> <tries>
  local i=0 st
  while [ "$i" -lt "$2" ]; do
    st=$(status)
    if printf '%s' "$st" | grep -Eq "^($1)$"; then printf '%s' "$st"; return 0; fi
    i=$((i + 1)); sleep 1
  done
  printf '%s' "${st:-unreadable}"; return 1
}

# The production predicate and the PRE-FIX predicate, each in its own subshell
# so the two adapter definitions never collide, both reading the SAME live pane.
# The pre-fix adapter is loaded from a MIRROR of bin/ - symlinks to every real
# library, with only backends/herdr.sh replaced by its pre-fix content - because
# the adapter resolves its sibling libraries relative to its own location. The
# old code therefore runs with exactly the libraries it shipped against.
MIRROR="$TMP_ROOT/prefix-mirror"
mkdir -p "$MIRROR/bin/backends"
for f in "$ROOT"/bin/*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in backends) continue ;; esac
  ln -s "$f" "$MIRROR/bin/${f##*/}"
done
for f in "$ROOT"/bin/backends/*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in herdr.sh) continue ;; esac
  ln -s "$f" "$MIRROR/bin/backends/${f##*/}"
done
git -C "$ROOT" show "$OLD_REF:bin/backends/herdr.sh" > "$MIRROR/bin/backends/herdr.sh" \
  || { echo "could not extract the pre-fix adapter from $OLD_REF" >&2; exit 1; }

proof_now() {  # -> prints yes|no
  env PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
    . "$1"/bin/fm-backend.sh
    if fm_backend_submit_pending_is_proof herdr "$2"; then printf yes; else printf no; fi
  ' _ "$ROOT" "$TARGET"
}

proof_prefix() {  # -> prints yes|no, using the adapter as it was before the fix
  env PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
    . "$1"/bin/fm-backend.sh
    . "$3"
    if fm_backend_herdr_submit_pending_is_proof "$2"; then printf yes; else printf no; fi
  ' _ "$ROOT" "$TARGET" "$MIRROR/bin/backends/herdr.sh"
}

# The real ring, with only the two dispatchers that TYPE replaced, so the
# classification under test - the real predicate against this real pane - runs
# production. A genuinely swallowed Enter cannot be forced on demand, so the
# post-submit verdict is the injected half and is named as such.
ring_pending() {  # -> ring rc
  local rc=0
  env PATH="$FAKEBIN:$ORIGINAL_PATH" FM_STATE_OVERRIDE="$TMP_ROOT/state" bash -c '
    . "$1"/bin/fm-task-inbox-lib.sh
    fm_backend_agent_state() { printf alive; }
    fm_backend_composer_state() { printf empty; }
    fm_backend_send_text_submit() { printf pending; }
    fm_task_inbox_ring herdr "$2" "$3" fm-t1
  ' _ "$ROOT" "$TARGET" "$REC" || rc=$?
  printf '%s' "$rc"
}

REC=$(env FM_STATE_OVERRIDE="$TMP_ROOT/state" bash -c \
  '. "$1"/bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$2" t1 "begin validation"' \
  _ "$ROOT" "$TMP_ROOT/state")

say "scenario 1: an IDLE real Codex pane keeps the per-pane stranded proof"
st=$(wait_status 'idle|done' 60) || { echo "codex never went idle (status=$st)" >&2; exit 1; }
printf 'live herdr agent_status = %s\n' "$st"
lab pane read "$PANE" --source visible --lines 40 > "$EV/herdr-01-codex-idle-pane.txt" 2>/dev/null || true
p=$(proof_now); printf 'production predicate: pending-is-proof=%s\n' "$p"
[ "$p" = yes ]; check "an idle Codex pane still proves a stranded doorbell" "proof lost on idle" $?
rc=$(ring_pending); printf 'fm_task_inbox_ring rc=%s\n' "$rc"
[ "$rc" = 4 ]; check "the real ring reports rc=4 (stranded input) on an idle Codex pane" "got rc=$rc" $?

say "scenario 2: a WORKING real Codex pane must NOT be read as a swallowed Enter"
env PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
  . "$1"/bin/fm-backend.sh
  . "$1"/bin/backends/herdr.sh
  fm_backend_herdr_send_text_submit "$2" "Print the numbers 1 through 60, one per line, slowly, then stop." 3 0.4 0.4
' _ "$ROOT" "$TARGET" > "$TMP_ROOT/submit.verdict" 2>/dev/null || true
printf 'landed-steer submit verdict = %s\n' "$(cat "$TMP_ROOT/submit.verdict")"
st=$(wait_status 'working' 60) || { echo "codex never reported working (status=$st)" >&2; exit 1; }
printf 'live herdr agent_status = %s\n' "$st"
lab pane read "$PANE" --source visible --lines 40 > "$EV/herdr-02-codex-working-pane.txt" 2>/dev/null || true
p=$(proof_now); o=$(proof_prefix)
printf 'production predicate: pending-is-proof=%s\npre-fix (%s) predicate: pending-is-proof=%s\n' "$p" "$OLD_REF" "$o"
[ "$p" = no ]; check "a post-submit working Codex pane is NOT proof of a swallowed Enter" "false stranded proof" $?
[ "$o" = yes ]; check "the pre-fix adapter DID call the same live pane a swallowed Enter (regression reproduced)" \
  "pre-fix adapter agreed, so this run does not reproduce the defect" $?
rc=$(ring_pending); printf 'fm_task_inbox_ring rc=%s\n' "$rc"
[ "$rc" = 0 ]; check "the real ring keeps a working pane advisory (rc=0), never reporting a delivered steer as stranded" "got rc=$rc" $?

printf '\n==== result: %s (%s on %s, lab %s) ====\n' \
  "$([ "$FAILED" = 0 ] && echo ALL-PASS || echo FAILURES)" "$CODEX_VER" "$HERDR_VER" "$SESSION"
exit "$FAILED"

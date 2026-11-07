#!/usr/bin/env bash
# Live scenario: a real Herdr lab pane whose task is retired (meta removed)
# while the watcher's bounded wait is open emits a real blocked edge. Feed the
# real record to handle_push_transition from LIB_DIR and print what happened.
# Usage: leftover-endpoint-live.sh <repo-root> <lib-dir> <label>
set -u
ROOT=$1; LIB_DIR=$2; LABEL=$3
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-leftover-$LABEL-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; herdr_safe_stop_and_delete "$SESSION"; }
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
CR=$(fm_backend_herdr_container_ensure /tmp); CONTAINER=${CR%%$'\t'*}; SEED=${CR#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-retired1" /tmp "$SEED")
read -r _T PANE_ID <<EOF
$IDS
EOF
TARGET="$SESSION:$PANE_ID"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-leftover.XXXXXX"); STATE="$SCRATCH/state"; mkdir -p "$STATE"
printf 'window=%s\nbackend=herdr\nkind=ship\n' "$TARGET" > "$STATE/retired1.meta"
# an unrelated live task so the state dir is not empty
printf 'window=%s:w99:p99\nbackend=herdr\nkind=ship\n' "$SESSION" > "$STATE/other.meta"
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-leftover --agent claude --state idle >/dev/null 2>&1
OUT="$SCRATCH/out"; RCF="$SCRATCH/rc"
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$TARGET" > "$OUT"; echo $? > "$RCF" ) &
WPID=$!
sleep 0.5
echo "[$LABEL] retiring task: removing retired1.meta while the wait is open"
rm -f "$STATE/retired1.meta"
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-leftover --agent claude --state blocked >/dev/null 2>&1
wait "$WPID"
REC=$(cat "$OUT"); echo "[$LABEL] wait rc=$(cat "$RCF") pane=$(fm_transition_pane_id "$REC") to=$(fm_transition_to_status "$REC")"
export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
. "$LIB_DIR/fm-push-transition-lib.sh"
WAKES=0; wake() { WAKES=$((WAKES+1)); echo "[$LABEL] WAKE: $1"; return 0; }
for edge in 1 2; do
  handle_push_transition herdr "$SESSION" "$REC"
  echo "[$LABEL] after edge $edge: wakes=$WAKES stale_rows=$(awk -F '\t' '$3=="stale"' "$STATE/.wake-queue" 2>/dev/null | wc -l | tr -d ' ')"
  rm -f "$STATE"/.herdr-escalated-* # let the second edge pass dedupe, like a re-block
done
echo "[$LABEL] wake-queue:"; cat "$STATE/.wake-queue" 2>/dev/null || echo "  (none)"
echo "[$LABEL] triage log:"; cat "$STATE/.watch-triage.log" 2>/dev/null || echo "  (none)"
echo "[$LABEL] RESULT wakes=$WAKES"

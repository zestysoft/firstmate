#!/usr/bin/env bash
# Local-only landing must use the durable done head, including across races.
# Once main moves past that head, a branch tip lands only when its content
# equals the recorded change applied to the current main.
# A landing that removes paths main has refuses unless each is confirmed.
# A newer report may move the recorded head only to a rebase, a continuation,
# or a re-application through a resolved conflict of the recorded change.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)

# fm-merge-local.sh refuses the supervision branch actor, because local-only
# landing is main-owned; tests/lib.sh pins the main actor, and the branch-actor
# case below sets it per call.
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local name=$1
  assert_no_record_violation
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/fm-guard.sh"
  chmod +x "$HOME_DIR/bin/fm-guard.sh"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\n' \
    "$PROJ" "$WT" > "$META"
}

# record_done [<at-epoch>|-]: report ready at that stamp (default 1790000000);
# "-" sends a report with no at= stamp.
record_done() {
  local line='done [at=1790000000]: ready in branch fm/local-task'
  case "${1:-}" in
    '') ;;
    -) line='done: ready in branch fm/local-task' ;;
    *) line="done [at=$1]: ready in branch fm/local-task" ;;
  esac
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    "$line" "$HOME_DIR/state" local-task "$META"
}

# run_landing <task> [args...]: one landing attempt. Whatever the reason, a
# refused landing must leave the task record byte-identical (or still absent);
# only a fixture that writes the record itself mid-landing sets
# FIXTURE_WRITES_RECORD=1. Callers often run this in a command substitution,
# where fail cannot end the suite, so a violation is also written to
# $RECORD_VIOLATIONS and checked by assert_no_record_violation.
RECORD_VIOLATIONS="$TMP_ROOT/record-violations"
record_violation() {
  printf '%s: %s\n' "${CASE##*/}" "$1" >> "$RECORD_VIOLATIONS"
  fail "$1"
}
assert_no_record_violation() {
  [ ! -s "$RECORD_VIOLATIONS" ] || fail "a refused landing changed its task record: $(cat "$RECORD_VIOLATIONS")"
}
run_landing() {
  local task=$1 meta="$HOME_DIR/state/$1.meta" before="$CASE/record-before-landing" rc=0
  shift
  rm -f -- "$before"
  [ ! -e "$meta" ] || cp -p -- "$meta" "$before"
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "${MERGE_SCRIPT:-$ROOT/bin/fm-merge-local.sh}" "$task" "$@" || rc=$?
  if [ "$rc" -ne 0 ] && [ "${FIXTURE_WRITES_RECORD:-0}" != 1 ]; then
    if [ -e "$before" ]; then
      cmp -s -- "$before" "$meta" || record_violation "a refused landing (exit $rc) changed the task record"
    else
      [ ! -e "$meta" ] || record_violation "a refused landing (exit $rc) created a task record"
    fi
  fi
  return "$rc"
}

land() {
  run_landing "${1:-local-task}"
}

assert_refused() {
  local out rc=0
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "landing unexpectedly succeeded: $out"
  assert_no_record_violation
  assert_contains "$out" 'comparison: recorded readiness' 'refusal omitted comparison context'
  if [ -f "$META" ]; then
    assert_contains "$out" "$(git -C "$PROJ" rev-parse refs/heads/fm/local-task)" 'refusal omitted candidate head'
    assert_contains "$out" "$BASE" 'refusal omitted local line head'
  fi
  assert_contains "$out" 'retry after configured approval' 'refusal omitted recovery action'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'refusal moved main'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'refusal left a dirty checkout'
  [ ! -e "$PROJ/approved.txt" ] || fail 'refusal left approved files behind'
}

test_branch_advance_does_not_change_approval() {
  make_case advanced
  record_done || fail 'done head was not accepted'
  git -C "$WT" commit -q --allow-empty -m Y
  assert_refused
  # Re-reading the old done report must not silently approve Y.
  record_done >/dev/null 2>&1 && fail 'stale done report was rebound to Y'
  git -C "$WT" reset -q --hard "$X"
  land >/dev/null || fail 'approved X did not land'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'landing did not use X'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'landing did not update the checkout'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'landing left a dirty checkout'
  pass 'branch advance refuses, and restoring the reported X lands exactly X'
}

# Ready, then main moves, then the worker rebases and reports ready again.
move_main_and_rebase() {
  printf 'other\n' > "$PROJ/other.txt"
  git -C "$PROJ" add other.txt
  git -C "$PROJ" commit -q -m 'main moves'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" rebase -q main
  Y=$(git -C "$WT" rev-parse HEAD)
}

test_rebased_same_change_replaces_recorded_head() {
  make_case rebased
  record_done 1790000100 || fail 'first ready report was not accepted'
  move_main_and_rebase
  record_done 1790000200 || fail 'ready report after a rebase of the same change was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the record still names the pre-rebase head'
  [ "$(fm_dod_local_done_at "$META")" = 1790000200 ] || fail 'the record did not take the newer stamp'
  land >/dev/null || fail 'the rebased head did not land'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$Y" ] || fail 'landing did not use the rebased head'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'landing did not bring the change'
  [ "$(cat "$PROJ/other.txt")" = 'other' ] || fail 'landing lost the newer main'
  pass 'a ready report after rebasing the same change re-records the head and lands it'
}

# Ready at X, then main moves and the worker rebases without reporting again.
# Re-reading the bound report, or an unstamped one, must not move the record to
# the rebased head; the content check still lands the rebase as approved X.
test_rereading_a_bound_report_cannot_take_a_rebase() {
  local line
  make_case rebased-reread
  record_done 1790000100 || fail 'first ready report was not accepted'
  move_main_and_rebase
  cp -p -- "$META" "$CASE/record-before-reread"
  for line in 1790000100 1790000050 -; do
    record_done "$line" >/dev/null 2>&1 && fail "re-reading report $line moved the record to the rebase"
    cmp -s -- "$CASE/record-before-reread" "$META" || fail "refused report $line changed the task record"
  done
  [ "$(fm_dod_local_done_head "$META")" = "$X" ] || fail 'the record no longer names the reported head'
  land >/dev/null 2>&1 || fail 'the content check did not land the rebase of the recorded change'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$Y" ] || fail 'landing did not use the rebased branch tip'
  cmp -s -- "$CASE/record-before-reread" "$META" || fail 'landing rewrote the task record'
  pass 'a re-read or unstamped report never moves the record to an unreported rebase'
}

test_rebased_revision_or_unbranched_head_refuses() {
  make_case rebased-changed
  record_done || fail 'first ready report was not accepted'
  move_main_and_rebase
  printf 'revised\n' > "$WT/approved.txt"
  git -C "$WT" commit -q -a --amend -m 'X revised'
  record_done >/dev/null 2>&1 && fail 'a rebase that changed the content replaced the record'
  [ "$(fm_dod_local_done_head "$META")" = "$X" ] || fail 'changed content moved the record'
  assert_refused

  make_case rebased-off-branch
  record_done || fail 'first ready report was not accepted'
  move_main_and_rebase
  git -C "$WT" checkout -q --detach "$Y"
  git -C "$PROJ" branch -q side "$Y"
  git -C "$PROJ" branch -q -f fm/local-task "$X"
  record_done >/dev/null 2>&1 && fail 'a head the ship branch does not point at replaced the record'
  [ "$(fm_dod_local_done_head "$META")" = "$X" ] || fail 'an off-branch head moved the record'
  assert_refused
  pass 'a rebase with different content, or a head off the ship branch, keeps the recorded head and refuses'
}

test_missing_and_malformed_head_refuse() {
  local value
  for value in missing empty abbreviated expression duplicate; do
    make_case "$value"
    case "$value" in
      missing) ;;
      empty) printf 'local_done_head=\n' >> "$META" ;;
      abbreviated) printf 'local_done_head=%s\n' "${X:0:8}" >> "$META" ;;
      expression) printf 'local_done_head=refs/heads/fm/local-task\n' >> "$META" ;;
      duplicate) printf 'local_done_head=%s\nlocal_done_head=%s\n' "$X" "$X" >> "$META" ;;
    esac
    assert_refused
  done
  pass 'missing, malformed and ambiguous done heads refuse without moving main'
}

# A refusal and the accepted retry both keep the whole record, spawn
# generation included, so cleanup can still identify this incarnation.
test_refused_then_accepted_landing_keeps_whole_record() {
  local before="$TMP_ROOT/kept-record"
  make_case kept
  record_done || fail 'done head was not accepted'
  [ "$(grep -c '^spawn_gen=fixture-1$' "$META")" = 1 ] || fail 'fixture record lacks its spawn generation'
  cp -p -- "$META" "$before"
  printf 'dirty\n' > "$PROJ/untracked.txt"
  land >/dev/null 2>&1 && fail 'landing into a dirty checkout succeeded'
  assert_no_record_violation
  rm -f -- "$PROJ/untracked.txt"
  land >/dev/null || fail 'the retry after the refusal did not land'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the retry did not land X'
  cmp -s -- "$before" "$META" || fail 'a successful landing changed the task record'
  [ "$(grep -c '^spawn_gen=fixture-1$' "$META")" = 1 ] || fail 'the landed record lost its spawn generation'
  pass 'a refused landing and its accepted retry both leave the whole record, spawn generation included'
}

# A Git shim moves the branch inside the final ref-changing Git invocation.
# It is a scheduling seam only: every Git operation still uses the real binary.
test_change_after_hold_check_refuses() {
  local real_git out rc
  real_git=$(command -v git)
  make_case race-branch
  record_done || fail 'race fixture done was not accepted'
  git -C "$WT" commit -q --allow-empty -m Y
  Y=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" reset -q --hard "$X"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *' merge --ff-only '*|*' update-ref '*' --stdin')
    "$REAL_GIT" -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y" || exit $?
    printf 'moved\n' > "$RACE_MARKER"
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$CASE/fakebin/git"
  rc=0
  out=$(PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" RACE_MARKER="$CASE/moved" \
    RACE_PROJ="$PROJ" RACE_Y="$Y" land 2>&1) || rc=$?
  [ -f "$CASE/moved" ] || fail 'branch race was not exercised'
  [ "$(git -C "$PROJ" rev-parse refs/heads/fm/local-task)" = "$Y" ] || fail 'worker branch did not move'
  [ "$rc" -ne 0 ] || fail "branch race unexpectedly landed: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'branch race moved main'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'branch race left a dirty checkout'
  [ ! -e "$PROJ/approved.txt" ] || fail 'branch race left approved files behind'
  pass 'a branch move inside the final Git invocation refuses without changing main or its checkout'
}

test_diverged_default_refuses() {
  make_case diverged
  record_done || fail 'diverged fixture done was not accepted'
  git -C "$PROJ" commit -q --allow-empty -m diverged
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  assert_refused
  pass 'a diverged default branch refuses without changing main or its checkout'
}

test_change_during_approval_check_refuses() {
  local mode out rc
  for mode in branch approval; do
    make_case "approval-$mode"
    record_done || fail 'approval race fixture done was not accepted'
    git -C "$WT" commit -q --allow-empty -m Y
    Y=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" reset -q --hard "$X"
    cp -R "$ROOT/bin" "$CASE/toolbin"
    cat > "$CASE/toolbin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_MODE" = branch ]; then
  git -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y"
else
  printf 'local_done_head=%s\n' "$RACE_Y" >> "$RACE_META"
fi
exit 3
SH
    rc=0
    out=$(MERGE_SCRIPT="$CASE/toolbin/fm-merge-local.sh" RACE_MODE="$mode" FIXTURE_WRITES_RECORD=1 \
      RACE_PROJ="$PROJ" RACE_Y="$Y" RACE_META="$META" land 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "approval race succeeded: $out"
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'approval race moved main'
  done
  pass 'approval and branch changes during the hold read refuse without moving main'
}

test_snapshot_cannot_pin_a_replacement_task() {
  local captured
  make_case stale-snapshot
  captured="$CASE/local-task.meta"
  cp "$META" "$captured"
  printf 'spawn_gen=replacement\n' >> "$META"
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    'done: ready' "$HOME_DIR/state" local-task "$captured" >/dev/null 2>&1 \
    && fail 'a stale snapshot pinned a replacement task'
  assert_no_regex '^local_done_head=' "$META" 'stale snapshot changed live readiness'
  pass 'captured metadata cannot pin a replacement task generation'
}

test_done_recording_preserves_caller_locks() {
  local caller
  for caller in ledger teardown; do
    make_case "locked-$caller"
    (
      local FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
      # shellcheck source=bin/fm-wake-lib.sh
      . "$ROOT/bin/fm-wake-lib.sh"
      local lock control='' owner
      lock=$(fm_meta_lock_path "$META") || exit 1
      if [ "$caller" = teardown ]; then
        control="$HOME_DIR/state/.control-local-task.lock"
        fm_lock_try_acquire "$control" || exit 1
      fi
      fm_lock_try_acquire "$lock" || exit 1
      fm_current_pid owner || exit 1
      trap 'fm_lock_release "$lock"; [ -z "$control" ] || fm_lock_release "$control"' EXIT
      FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: ready' "$HOME_DIR/state" local-task "$META" meta-locked || exit 1
      [ "$(fm_dod_local_done_head "$META")" = "$X" ] || exit 1
      FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: ready again' "$HOME_DIR/state" local-task "$META" meta-locked || exit 1
      git -C "$WT" commit -q --allow-empty -m Y || exit 1
      if FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
        'done: changed' "$HOME_DIR/state" local-task "$META" meta-locked >/dev/null; then
        exit 1
      fi
      [ "$(fm_dod_local_done_head "$META")" = "$X" ] || exit 1
      [ "$(cat "$lock/pid")" = "$owner" ] || exit 1
      [ -z "$control" ] || [ "$(cat "$control/pid")" = "$owner" ] || exit 1
    ) || fail "$caller: done recording failed or changed the caller's locks"
  done
  pass 'ledger and teardown record the first done head without reacquiring or releasing caller locks'
}

test_two_tasks_cannot_undo_a_same_tree_landing() {
  local real_git real_sleep other first_pid second_pid first_rc=0 second_rc=0 i project_lock
  make_case same-tree
  record_done || fail 'first task readiness was not accepted'
  other=$(printf 'second task\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$BASE")
  git -C "$PROJ" update-ref refs/heads/fm/other-task "$other"
  printf 'kind=ship\nmode=local-only\nbranch=fm/other-task\nproject=%s\nspawn_gen=fixture-2\nlocal_done_head=%s\n' \
    "$PROJ" "$other" > "$HOME_DIR/state/other-task.meta"
  [ "$other" != "$X" ] || fail 'same-tree commits were not distinct'
  [ "$(git -C "$PROJ" rev-parse "$other^{tree}")" = "$(git -C "$PROJ" rev-parse "$X^{tree}")" ] \
    || fail 'the two approved commits have different trees'
  real_git=$(command -v git)
  real_sleep=$(command -v sleep)
  project_lock="$(git -C "$PROJ" rev-parse --absolute-git-dir)/fm-local-landing.lock"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
wait_for() {
  local i=0
  while [ ! -f "$RACE_DIR/$1" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$RACE_DIR/$1" ]
}
case "$*" in
  *' read-tree -m -u '*)
    if [ ! -f "$RACE_DIR/$RACE_ROLE.staged" ]; then
      : > "$RACE_DIR/$RACE_ROLE.ready"
      if [ "$RACE_ROLE" = first ]; then
        wait_for release-first || exit 90
      else
        wait_for first.staged || exit 91
      fi
      "$REAL_GIT" "$@" || exit $?
      : > "$RACE_DIR/$RACE_ROLE.staged"
      exit 0
    fi
    ;;
  *' update-ref '*' --stdin')
    if [ "$RACE_ROLE" = first ]; then
      if [ -f "$RACE_DIR/second.ready" ]; then
        wait_for second.staged || exit 92
      fi
    else
      wait_for first.updated || exit 93
    fi
    "$REAL_GIT" "$@" || exit $?
    : > "$RACE_DIR/$RACE_ROLE.updated"
    exit 0
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  cat > "$CASE/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_ROLE" = second ] && [ -d "$RACE_PROJECT_LOCK" ] \
  && [ -d "$RACE_CONTROL_LOCK" ] && [ ! -f "$RACE_DIR/second.ready" ]; then
  : > "$RACE_DIR/second.waiting"
fi
exec "$REAL_SLEEP" "$@"
SH
  chmod +x "$CASE/fakebin/git" "$CASE/fakebin/sleep"
  (
    first_pid='' second_pid=''
    trap ': > "$CASE/release-first"; [ -z "$first_pid" ] || { kill "$first_pid" 2>/dev/null || true; wait "$first_pid" 2>/dev/null || true; }; [ -z "$second_pid" ] || { kill "$second_pid" 2>/dev/null || true; wait "$second_pid" 2>/dev/null || true; }' EXIT
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=first \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land > "$CASE/first.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    first_pid=$!
    i=0
    # A first landing that exits before its checkout update was refused, not
    # raced; name its own output so a refusal cannot read as corruption.
    while [ ! -f "$CASE/first.ready" ] && [ "$i" -lt 300 ]; do
      kill -0 "$first_pid" 2>/dev/null || break
      sleep 0.1
      i=$((i + 1))
    done
    [ -f "$CASE/first.ready" ] || fail "first landing never reached its checkout update: $(cat "$CASE/first.out")"
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=second \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land other-task > "$CASE/second.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    second_pid=$!
    i=0
    while [ "$i" -lt 300 ]; do
      [ ! -f "$CASE/second.ready" ] || break
      if [ -f "$CASE/second.waiting" ]; then
        [ -d "$project_lock" ] || fail 'the contended project lock disappeared'
        kill -0 "$second_pid" 2>/dev/null || fail 'second landing exited before contending'
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    [ "$i" -lt 300 ] || fail 'second landing neither prepared nor contended for the checkout'
    : > "$CASE/release-first"
    wait "$first_pid" || first_rc=$?
    wait "$second_pid" || second_rc=$?
    first_pid='' second_pid=''
    [ "$first_rc" -eq 0 ] || fail "first landing failed: $(cat "$CASE/first.out")"
    [ "$second_rc" -ne 0 ] || fail "second landing unexpectedly succeeded: $(cat "$CASE/second.out")"
    [ -f "$CASE/first.updated" ] || fail 'the first ref transaction did not run'
    if [ -f "$CASE/second.ready" ]; then
      [ -f "$CASE/second.staged" ] || fail 'the competing checkout was never staged'
    fi
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the competing task moved the landed head'
    [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'the competing task reverted the landed files'
    [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'the competing task dirtied the landed checkout'
  ) || fail 'two-task same-tree landing case failed; the line above names the broken expectation'
  pass 'two approved tasks with the same tree cannot roll back a successful landing'
}

# Move main past the recorded head with an unrelated commit, as another landing would.
advance_main() {
  printf 'other work\n' > "$PROJ/other.txt"
  git -C "$PROJ" add other.txt
  git -C "$PROJ" commit -q -m other
  BASE=$(git -C "$PROJ" rev-parse HEAD)
}

assert_moved_main_refused() {
  local out rc=0 label=$1
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: landing unexpectedly succeeded: $out"
  assert_no_record_violation
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail "$label: refusal moved main"
  [ "$(git -C "$PROJ" rev-parse "refs/heads/fm/local-task")" = "$(git -C "$WT" rev-parse HEAD)" ] \
    || fail "$label: refusal moved the ship branch"
  LAST_OUT=$out
}

assert_landed_tip() {
  local tip out label=$1
  tip=$(git -C "$WT" rev-parse HEAD)
  out=$(land 2>&1) || fail "$label: landing refused: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$tip" ] || fail "$label: main is not the branch tip"
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail "$label: approved content missing"
  [ "$(cat "$PROJ/other.txt")" = 'other work' ] || fail "$label: main's newer content missing"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "$label: landing left a dirty checkout"
  [ "$(fm_dod_local_done_head "$META")" = "$X" ] || fail "$label: landing changed the recorded head"
  assert_contains "$out" "whose tree equals recorded done head $X" "$label: landing did not name the recorded head"
  assert_contains "$out" "file(s) in the landed main index and checkout are byte-identical to branch fm/local-task at $tip" "$label: no landed-files proof"
  assert_contains "$out" "are present after it except 0 confirmed deletion(s); none missing" "$label: no main-paths proof"
}

test_stale_commit_name_lands_rebased_branch() {
  make_case stale-name
  record_done || fail 'stale-name fixture done was not accepted'
  advance_main
  git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
  [ "$(git -C "$WT" rev-parse HEAD)" != "$X" ] || fail 'rebase kept the recorded commit name'
  assert_landed_tip 'stale name'
  pass 'a rebase of the recorded head onto a moved main lands under its new commit name'
}

test_content_equal_branch_lands() {
  make_case content-equal
  record_done || fail 'content-equal fixture done was not accepted'
  advance_main
  # Rebuild the same change as two commits with different messages.
  git -C "$WT" reset -q --hard main
  printf 'approved' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m 'first half'
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" commit -q -am 'second half'
  [ -z "$(git -C "$WT" diff "$X" HEAD -- approved.txt)" ] || fail 'rebuilt change differs from X'
  assert_landed_tip 'content equal'
  pass 'a branch rebuilt with different history but the same content as the recorded change lands'
}

test_differing_tree_refuses_after_main_moves() {
  make_case differing
  record_done || fail 'differing fixture done was not accepted'
  advance_main
  git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
  printf 'unapproved\n' > "$WT/extra.txt"
  git -C "$WT" add extra.txt
  git -C "$WT" commit -q -m extra
  assert_moved_main_refused 'differing tree'
  assert_contains "$LAST_OUT" 'content differs from the recorded local done head' 'differing tree refusal reason'
  [ ! -e "$PROJ/extra.txt" ] || fail 'differing tree left unapproved files behind'
  [ ! -e "$PROJ/approved.txt" ] || fail 'differing tree left approved files behind'
  pass 'a rebased branch whose content differs from the recorded change refuses'
}

test_conflicting_change_refuses_after_main_moves() {
  make_case conflict
  record_done || fail 'conflict fixture done was not accepted'
  printf 'main version\n' > "$PROJ/approved.txt"
  git -C "$PROJ" add approved.txt
  git -C "$PROJ" commit -q -m 'main edits the same file'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  # A worker's resolution that keeps X's text is still new, unreviewed content.
  git -C "$WT" reset -q --hard main
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" commit -q -am resolved
  assert_moved_main_refused 'conflict'
  assert_contains "$LAST_OUT" 'conflicts with the current main' 'conflict refusal reason'
  assert_contains "$LAST_OUT" "$X conflicts with the current main ($BASE)" 'conflict refusal omitted the compared heads'
  assert_contains "$LAST_OUT" 'carrier proof failed before approval' 'conflict refusal blamed the approval recheck'
  assert_contains "$LAST_OUT" "FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$HOME_DIR/state $ROOT/bin/fm-crew-state.sh local-task" 'conflict refusal omitted the readiness reconciliation command'
  [ "$(cat "$PROJ/approved.txt")" = 'main version' ] || fail 'conflict refusal changed main content'
  pass 'a recorded change that conflicts with the moved main refuses even after a resolution'
}

test_uncommitted_work_refuses_after_main_moves() {
  local kind
  for kind in tracked untracked; do
    make_case "dirty-$kind"
    record_done || fail 'dirty fixture done was not accepted'
    advance_main
    git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
    if [ "$kind" = tracked ]; then
      printf 'local edit\n' >> "$PROJ/other.txt"
    else
      printf 'stray\n' > "$PROJ/stray.txt"
    fi
    assert_moved_main_refused "uncommitted $kind"
    assert_contains "$LAST_OUT" 'dirty working tree' "uncommitted $kind refusal reason"
    [ ! -e "$PROJ/approved.txt" ] || fail "uncommitted $kind left approved files behind"
  done
  pass 'uncommitted work in the project checkout refuses a content-equal landing'
}

test_already_landed_content_not_landed_twice() {
  local twin mode
  for mode in recorded rebased; do
    make_case "landed-$mode"
    record_done || fail 'already-landed fixture done was not accepted'
    # Another task already landed the same content under a different commit.
    twin=$(printf 'twin task\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$(git -C "$PROJ" rev-parse main)")
    git -C "$PROJ" merge -q --ff-only "$twin"
    BASE=$twin
    [ "$mode" = recorded ] || git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
    assert_moved_main_refused "already landed ($mode)"
    assert_contains "$LAST_OUT" 'already on main; nothing to land' "already landed ($mode) refusal reason"
    [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail "already landed ($mode) changed main content"
  done
  pass 'content already on main is refused rather than landed a second time'
}

test_merge_history_refuses_after_main_moves() {
  make_case merge-history
  record_done || fail 'merge-history fixture done was not accepted'
  advance_main
  git -C "$WT" merge -q --no-edit main
  [ "$(git -C "$WT" rev-parse 'HEAD^{tree}')" = "$(git -C "$PROJ" merge-tree --write-tree main "$X" | head -1)" ] \
    || fail 'merge fixture does not carry the recorded change'
  assert_moved_main_refused 'merge history'
  assert_contains "$LAST_OUT" 'merge commits above main' 'merge history refusal reason'
  pass 'a branch that merged main instead of rebasing refuses even with matching content'
}

test_missing_recorded_commit_refuses() {
  make_case missing-commit
  printf 'local_done_head=%s\n' "$(printf '%040d' 0 | tr 0 a)" >> "$META"
  assert_refused
  pass 'a well-formed recorded head that names no commit refuses'
}

land_confirming() {
  MERGE_SCRIPT='' run_landing local-task "$@"
}

# Main gains files after the worker started, as an earlier landing would.
main_adds_files() {
  local path
  for path in "$@"; do
    printf 'landed %s\n' "$path" > "$PROJ/$path"
    git -C "$PROJ" add -- "$path"
  done
  git -C "$PROJ" commit -q -m 'earlier landing adds files'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
}

assert_deletion_refused() {
  local label=$1 out rc=0
  shift
  out=$(land_confirming "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: landing unexpectedly succeeded: $out"
  assert_no_record_violation
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail "$label: refusal moved main"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "$label: refusal left a dirty checkout"
  [ ! -e "$PROJ/approved.txt" ] || fail "$label: refusal left approved files behind"
  LAST_OUT=$out
}

test_landing_that_drops_landed_files_refuses_by_name() {
  local stale tip
  make_case drops-landed
  main_adds_files kept.txt 'lost two.txt'
  # The worker's commit sits on main but its content came from the older base.
  stale=$(printf 'stale content\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$BASE")
  git -C "$WT" reset -q --hard "$stale"
  record_done || fail 'stale-content fixture done was not accepted'
  assert_deletion_refused 'unconfirmed'
  assert_contains "$LAST_OUT" 'would delete 2 path(s) that main has' 'refusal did not count the paths'
  assert_contains "$LAST_OUT" '  kept.txt' 'refusal did not name kept.txt'
  assert_contains "$LAST_OUT" '  lost\ two.txt' 'refusal did not name lost two.txt'
  assert_contains "$LAST_OUT" "--confirm-deletion kept.txt --confirm-deletion lost\\ two.txt" \
    'refusal did not show how to confirm a deliberate deletion'
  [ "$(cat "$PROJ/lost two.txt")" = 'landed lost two.txt' ] || fail 'refusal lost the landed file'
  assert_deletion_refused 'partly confirmed' --confirm-deletion kept.txt
  assert_contains "$LAST_OUT" 'would delete 2 path(s)' 'a partial confirmation was accepted'
  assert_deletion_refused 'extra confirmation' --confirm-deletion kept.txt \
    --confirm-deletion 'lost two.txt' --confirm-deletion approved.txt
  assert_contains "$LAST_OUT" 'does not remove from main' 'an extra confirmation was accepted'
  assert_contains "$LAST_OUT" '  approved.txt' 'the extra confirmation was not named'

  make_case carries-landed
  main_adds_files kept.txt 'lost two.txt'
  git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
  tip=$(git -C "$WT" rev-parse HEAD)
  record_done || fail 'carrying fixture done was not accepted'
  land_confirming >/dev/null 2>&1 || fail 'a branch that carries the landed files was refused'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$tip" ] || fail 'the carrying branch did not land'
  [ "$(cat "$PROJ/lost two.txt")" = 'landed lost two.txt' ] || fail 'the carrying landing lost a file'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'the carrying landing lost the change'
  pass 'a landing that drops files main has refuses by name, and lands once the branch carries them'
}

test_deliberate_deletion_lands_when_confirmed() {
  local tip out
  make_case deliberate
  main_adds_files doomed.txt
  git -C "$WT" reset -q --hard main
  git -C "$WT" rm -q doomed.txt
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m 'X deletes doomed.txt'
  tip=$(git -C "$WT" rev-parse HEAD)
  record_done || fail 'deliberate-deletion fixture done was not accepted'
  assert_deletion_refused 'unconfirmed deliberate deletion'
  assert_contains "$LAST_OUT" '--confirm-deletion doomed.txt' 'refusal did not offer the confirmation'
  out=$(land_confirming --confirm-deletion doomed.txt 2>&1) || fail "confirmed deletion refused: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$tip" ] || fail 'confirmed deletion did not land the branch'
  [ ! -e "$PROJ/doomed.txt" ] || fail 'confirmed deletion left the deleted file'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'confirmed deletion lost the change'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'confirmed deletion left a dirty checkout'
  assert_contains "$out" 'deleted 1 path(s) the operator confirmed' 'landing did not report the deletion'
  pass 'a branch that deliberately deletes a file lands once the operator confirms it by name'
}

test_content_equal_rebase_with_deletion_needs_confirmation() {
  make_case content-equal-delete
  main_adds_files doomed.txt
  git -C "$WT" reset -q --hard main
  git -C "$WT" rm -q doomed.txt
  git -C "$WT" commit -q -m 'X deletes doomed.txt'
  X=$(git -C "$WT" rev-parse HEAD)
  record_done || fail 'content-equal deletion fixture done was not accepted'
  advance_main
  git -C "$WT" -c advice.skippedCherryPicks=false rebase -q main
  assert_moved_main_refused 'unconfirmed rebased deletion'
  assert_contains "$LAST_OUT" '  doomed.txt' 'rebased deletion refusal did not name the path'
  LAST_OUT=$(land_confirming --confirm-deletion doomed.txt 2>&1) || fail "confirmed rebased deletion refused: $LAST_OUT"
  assert_contains "$LAST_OUT" 'except 1 confirmed deletion(s); none missing' 'rebased deletion proof did not count the confirmed deletion'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$(git -C "$WT" rev-parse HEAD)" ] || fail 'rebased deletion did not land'
  [ ! -e "$PROJ/doomed.txt" ] || fail 'rebased deletion kept the file'
  [ "$(cat "$PROJ/other.txt")" = 'other work' ] || fail "rebased deletion lost main's newer content"
  pass 'a content-equal rebase that deletes a file needs the same confirmation, then lands'
}

test_branch_actor_is_refused_by_the_tool() {
  local out rc=0
  make_case branch-actor
  record_done || fail 'branch-actor fixture done was not accepted'
  out=$(FM_SUPERVISION_ACTOR=branch land 2>&1) || rc=$?
  [ "$rc" -eq 6 ] || fail "the branch actor was not refused by the tool: $rc $out"
  assert_contains "$out" 'local-only landing (fm-merge-local) refused - the supervision branch never performs this action' \
    'the branch-actor refusal did not name the role partition'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'the branch-actor refusal moved main'
  [ ! -e "$PROJ/approved.txt" ] || fail 'the branch-actor refusal left approved files behind'
  FM_SUPERVISION_ACTOR=main land >/dev/null 2>&1 || fail 'the main actor could not land after the branch refusal'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the main actor did not land the recorded head'
  pass 'the supervision branch actor is refused by the landing tool itself, and main then lands'
}

test_bad_confirmation_arguments_refuse() {
  local out rc args
  make_case bad-args
  record_done || fail 'bad-args fixture done was not accepted'
  for args in '--confirm-deletion' '--confirm-deletion=' '--unknown'; do
    rc=0
    # shellcheck disable=SC2086 # Each case is one deliberately unquoted word.
    out=$(land_confirming $args 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "'$args' did not refuse as a usage error: $rc $out"
  done
  rc=0
  out=$(land_confirming --confirm-deletion '' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an empty confirmation did not refuse as a usage error: $rc $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'a usage error moved main'
  pass 'malformed confirmation arguments refuse without landing'
}

# A follow-up commit on top of the reported X: it adds a file and edits the line
# X added, the shape of a second commit that finishes a two-commit change.
commit_follow_up() {
  printf 'approved X\nfollow-up\n' > "$WT/approved.txt"
  printf 'second half\n' > "$WT/second.txt"
  git -C "$WT" add approved.txt second.txt
  git -C "$WT" commit -q -m 'second half of the change'
  Y=$(git -C "$WT" rev-parse HEAD)
}

assert_head_kept() {  # <label>
  [ "$(fm_dod_local_done_head "$META")" = "$X" ] || fail "$1: the recorded head moved"
}

assert_landed_whole() {  # <label> <head>
  land >/dev/null 2>&1 || fail "$1: the newer reported head did not land"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$2" ] || fail "$1: landing did not use the newer reported head"
  [ "$(cat "$PROJ/second.txt")" = 'second half' ] || fail "$1: landing lost the second commit"
  [ "$(cat "$PROJ/approved.txt")" = "$(printf 'approved X\nfollow-up')" ] || fail "$1: landing lost the follow-up edit"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "$1: landing left a dirty checkout"
}

test_newer_report_of_continued_branch_replaces_head() {
  make_case continued
  record_done 1790000100 || fail 'first ready report was not accepted'
  commit_follow_up
  record_done 1790000200 || fail 'a newer ready report whose branch carries X was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the record still names the first reported head'
  [ "$(fm_dod_local_done_at "$META")" = 1790000200 ] || fail 'the record did not bind the newer report'
  assert_landed_whole continued "$Y"

  make_case continued-rebased
  record_done 1790000100 || fail 'first ready report was not accepted'
  commit_follow_up
  move_main_and_rebase
  record_done 1790000200 || fail 'a newer report of the rebased two-commit branch was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the record still names the pre-rebase head'
  assert_landed_whole continued-rebased "$Y"
  [ "$(cat "$PROJ/other.txt")" = 'other' ] || fail 'landing lost the newer main'
  pass 'a newer ready report whose branch passed through the recorded tree and went forward replaces the head and lands whole'
}

test_two_commit_change_is_never_half_landed() {
  make_case half
  record_done 1790000100 || fail 'first ready report was not accepted'
  commit_follow_up
  # No newer report: the record keeps X, and neither X nor Y lands.
  assert_refused
  move_main_and_rebase
  assert_refused
  assert_head_kept 'unreported second commit'
  [ ! -e "$PROJ/second.txt" ] || fail 'a refusal left the second commit behind'
  record_done 1790000200 || fail 'the newer report of the whole change was refused'
  assert_landed_whole half "$Y"
  pass 'a branch carrying a second, unreported commit refuses rather than landing half, and lands whole once reported'
}

test_rereading_a_bound_report_cannot_take_later_work() {
  make_case reread
  record_done 1790000100 || fail 'first ready report was not accepted'
  record_done 1790000200 || fail 'a newer report of the same head was refused'
  [ "$(fm_dod_local_done_at "$META")" = 1790000200 ] || fail 'the newer report of the same head was not bound'
  commit_follow_up
  record_done 1790000200 >/dev/null 2>&1 && fail 're-reading the bound report moved the head to unreported work'
  record_done 1790000100 >/dev/null 2>&1 && fail 'an older report moved the head'
  record_done - >/dev/null 2>&1 && fail 'an unstamped report moved the head'
  assert_head_kept reread
  assert_refused
  pass 'a report already bound, an older one, or an unstamped one never moves the head to later work'
}

test_newer_report_with_changed_tree_refuses() {
  local label
  for label in amended rewritten reverted conflict-resolved; do
    make_case "changed-$label"
    record_done 1790000100 || fail "$label: first ready report was not accepted"
    case "$label" in
      amended)
        printf 'approved X, revised\n' > "$WT/approved.txt"
        git -C "$WT" commit -q -a --amend -m 'X revised'
        ;;
      rewritten)
        # The idle-fleet shape: the same base, a replacement commit, not a continuation.
        git -C "$WT" reset -q --hard "$BASE"
        printf 'approved X\nmore\n' > "$WT/approved.txt"
        git -C "$WT" add approved.txt
        git -C "$WT" commit -q -m 'X rewritten'
        ;;
      reverted)
        commit_follow_up
        git -C "$WT" rm -q approved.txt
        git -C "$WT" commit -q -m 'drop the recorded file again'
        ;;
      conflict-resolved)
        printf 'main version\n' > "$PROJ/approved.txt"
        git -C "$PROJ" add approved.txt
        git -C "$PROJ" commit -q -m 'main edits the same file'
        BASE=$(git -C "$PROJ" rev-parse HEAD)
        git -C "$WT" reset -q --hard main
        printf 'approved X\n' > "$WT/approved.txt"
        git -C "$WT" commit -q -am resolved
        ;;
    esac
    record_done 1790000200 >/dev/null 2>&1 && fail "$label: a newer report with a changed tree replaced the record"
    assert_head_kept "$label"
    if [ "$label" = conflict-resolved ]; then
      local out rc=0
      out=$(land 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail "conflict-resolved: landing succeeded: $out"
      [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'conflict-resolved: refusal moved main'
    else
      assert_refused
    fi
  done
  pass 'an amended, rewritten, partly reverted, or conflict-resolved change keeps the recorded head even on a newer report'
}

test_newer_report_off_fast_forward_refuses() {
  local older
  make_case merge-commit
  record_done 1790000100 || fail 'first ready report was not accepted'
  commit_follow_up
  printf 'other\n' > "$PROJ/other.txt"
  git -C "$PROJ" add other.txt
  git -C "$PROJ" commit -q -m 'main moves'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" merge -q --no-edit main
  record_done 1790000200 >/dev/null 2>&1 && fail 'a newer report over merge history replaced the record'
  assert_head_kept merge-commit

  make_case older-base
  older=$BASE
  move_main_and_rebase
  record_done 1790000100 || fail 'first ready report was not accepted'
  X=$(git -C "$WT" rev-parse HEAD)
  # The newer head forks from the older main: not a fast-forward of the record's base.
  git -C "$WT" reset -q --hard "$older"
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m 'X on the older main'
  commit_follow_up
  record_done 1790000200 >/dev/null 2>&1 && fail 'a newer report from an older fork point replaced the record'
  assert_head_kept older-base
  pass 'a newer report over merge history or from an older fork point keeps the recorded head'
}

test_missing_record_or_report_refuses() {
  make_case legacy
  # A record kept before stamps: it may adopt a stamp for its own head only.
  printf 'local_done_head=%s\n' "$X" >> "$META"
  commit_follow_up
  record_done 1790000200 >/dev/null 2>&1 && fail 'a stampless record moved to a newer head'
  assert_head_kept legacy
  git -C "$WT" reset -q --hard "$X"
  record_done 1790000200 || fail 'a stampless record refused its own head'
  [ "$(fm_dod_local_done_at "$META")" = 1790000200 ] || fail 'the stampless record did not adopt the stamp'

  make_case no-report
  commit_follow_up
  assert_refused

  make_case no-record
  rm -f "$META"
  record_done 1790000200 >/dev/null 2>&1 && fail 'a task with no record accepted a report'
  [ ! -e "$META" ] || fail 'a report created a task record'
  assert_refused
  pass 'a stampless record never moves, and a task with no report or no record refuses'
}

# The re-application shape: main and the change both append to a shared ledger,
# so once main moves the recorded change conflicts and the worker resolves it
# by hand. Main also holds doomed.txt for the deletion case.
write_ledger() {  # <dir> <row>...
  local dir=$1 row sep=''
  shift
  {
    printf '[\n'
    for row in "$@"; do
      printf '%b  {"row": "%s"}' "$sep" "$row"
      sep=',\n'
    done
    printf '\n]\n'
  } > "$dir/ledger.json"
}

make_ledger_case() {  # <name>
  make_case "$1"
  write_ledger "$PROJ" base
  printf 'kept\n' > "$PROJ/doomed.txt"
  git -C "$PROJ" add ledger.json doomed.txt
  git -C "$PROJ" commit -q -m 'main keeps a ledger'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" reset -q --hard main
  printf 'approved X\n' > "$WT/approved.txt"
  write_ledger "$WT" base X
  git -C "$WT" add approved.txt ledger.json
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
}

main_ledger() {  # <row>...: main moves with its own ledger rows
  write_ledger "$PROJ" "$@"
  git -C "$PROJ" commit -q -am 'main records a row'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
}

# reapply <row>...: rebuild the change by hand on the current main, resolving
# the ledger to the given rows; REAPPLY_DELETES names a file the change removes.
reapply() {
  git -C "$WT" reset -q --hard main
  printf 'approved X\n' > "$WT/approved.txt"
  write_ledger "$WT" "$@"
  git -C "$WT" add approved.txt ledger.json
  [ -z "${REAPPLY_DELETES:-}" ] || git -C "$WT" rm -q -- "$REAPPLY_DELETES"
  git -C "$WT" commit -q -m 'X re-applied'
  Y=$(git -C "$WT" rev-parse HEAD)
}

# Proves a case is the conflicted shape the older checks cannot accept, so the
# acceptance or refusal below is the re-application rule's own verdict.
assert_conflicting_reapplication() {  # <label> <recorded>
  git -C "$PROJ" merge-tree --write-tree "$BASE" "$2" >/dev/null 2>&1 \
    && fail "$1: the recorded change does not conflict with main"
  fm_dod_local_done_head_rebased "$META" local-task "$2" "$Y" \
    && fail "$1: the rebase check already accepts this head"
  fm_dod_local_done_head_continues "$META" local-task "$2" "$Y" \
    && fail "$1: the continuation check already accepts this head"
  return 0
}

assert_ledger() {  # <label> <row>...
  local label=$1
  shift
  write_ledger "$CASE" "$@"
  cmp -s -- "$CASE/ledger.json" "$PROJ/ledger.json" || fail "$label: landed ledger differs: $(cat "$PROJ/ledger.json")"
}

test_newer_report_of_reapplied_change_replaces_head() {
  local first
  make_ledger_case reapplied
  record_done 1790000100 || fail 'first ready report was not accepted'
  main_ledger base main1
  reapply base main1 X
  assert_conflicting_reapplication reapplied "$X"
  record_done 1790000200 || fail 'a newer report of the change re-applied through a resolved conflict was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the record still names the superseded head'
  [ "$(fm_dod_local_done_at "$META")" = 1790000200 ] || fail 'the record did not bind the newer report'
  # The worker then records its replay in the ledger, and main moves again:
  # the second re-application supersedes the first one in turn.
  write_ledger "$WT" base main1 X 'X replay'
  git -C "$WT" commit -q -am 'record the replay'
  first=$(git -C "$WT" rev-parse HEAD)
  record_done 1790000300 || fail 'a newer report with a ledger note on the re-application was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$first" ] || fail 'the ledger note did not replace the head'
  main_ledger base main1 main2
  reapply base main1 main2 X 'X replay'
  assert_conflicting_reapplication 'second reapplication' "$first"
  record_done 1790000400 || fail 'a second re-application was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the second re-application did not replace the head'
  land >/dev/null || fail 'the re-applied head did not land'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$Y" ] || fail 'landing did not use the re-applied head'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'landing did not bring the change'
  assert_ledger reapplied base main1 main2 X 'X replay'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'landing left a dirty checkout'
  pass 'a newer report of the change re-applied through a resolved conflict replaces the head, twice, and lands exactly it'
}

test_newer_report_of_reapplication_refusals() {
  local label mid side
  for label in revised extra-path dropped-main-row dropped-change-row older-fork merge-commit; do
    make_ledger_case "reapplied-$label"
    record_done 1790000100 || fail "$label: first ready report was not accepted"
    main_ledger base main1
    case "$label" in
      revised)
        reapply base main1 X
        printf 'approved X, revised\n' > "$WT/approved.txt"
        git -C "$WT" commit -q -a --amend -m 'X revised'
        ;;
      extra-path)
        reapply base main1 X
        printf 'unapproved\n' > "$WT/extra.txt"
        git -C "$WT" add extra.txt
        git -C "$WT" commit -q -m extra
        ;;
      dropped-main-row) reapply base X ;;
      dropped-change-row) reapply base main1 ;;
      older-fork)
        mid=$BASE
        main_ledger base main1 main2
        git -C "$WT" reset -q --hard "$mid"
        # The content equals a re-application on the current main; only the
        # fork point differs, so landing it would not be a fast-forward.
        printf 'approved X\n' > "$WT/approved.txt"
        write_ledger "$WT" base main1 main2 X
        git -C "$WT" add approved.txt ledger.json
        git -C "$WT" commit -q -m 'X re-applied on an older main'
        ;;
      merge-commit)
        side=$(git -C "$WT" commit-tree "main^{tree}" -p main -m side)
        reapply base main1 X
        git -C "$WT" merge -q --no-ff --no-edit "$side"
        [ "$(git -C "$WT" rev-parse 'HEAD^{tree}')" = "$(git -C "$WT" rev-parse "$Y^{tree}")" ] \
          || fail 'merge-commit: the merge changed the re-applied content'
        ;;
    esac
    Y=$(git -C "$WT" rev-parse HEAD)
    record_done 1790000200 >/dev/null 2>&1 && fail "$label: a newer report replaced the record"
    assert_head_kept "$label"
    assert_refused
  done
  pass 'a re-application that revises a path, adds one, drops a row from either side, forks from an older main, or merges keeps the recorded head and refuses'
}

# Line-shaped blobs holding NUL bytes would pass the line rule, so only the
# text-file rule refuses a hand resolution of a conflict git cannot merge as text.
test_reapplied_binary_conflict_refuses() {
  make_case reapplied-binary
  printf 'A\0\n' > "$PROJ/blob.bin"
  git -C "$PROJ" add blob.bin
  git -C "$PROJ" commit -q -m 'main keeps a blob'
  git -C "$WT" reset -q --hard main
  printf 'A\0\nB\0\n' > "$WT/blob.bin"
  git -C "$WT" commit -q -am 'X edits the blob'
  X=$(git -C "$WT" rev-parse HEAD)
  record_done 1790000100 || fail 'first ready report was not accepted'
  printf 'A\0\nC\0\n' > "$PROJ/blob.bin"
  git -C "$PROJ" commit -q -am 'main edits the blob'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" reset -q --hard main
  printf 'A\0\nB\0\nC\0\n' > "$WT/blob.bin"
  git -C "$WT" commit -q -am 'blob resolved by hand'
  Y=$(git -C "$WT" rev-parse HEAD)
  assert_conflicting_reapplication binary "$X"
  record_done 1790000200 >/dev/null 2>&1 && fail 'binary: a hand-resolved binary conflict replaced the record'
  assert_head_kept binary
  assert_refused
  pass 'a re-application through a hand-resolved binary conflict keeps the recorded head and refuses'
}

test_reapplied_deletion_needs_confirmation() {
  make_ledger_case reapplied-delete
  git -C "$WT" rm -q doomed.txt
  git -C "$WT" commit -q --amend -m 'X deletes doomed.txt'
  X=$(git -C "$WT" rev-parse HEAD)
  record_done 1790000100 || fail 'first ready report was not accepted'
  main_ledger base main1
  REAPPLY_DELETES=doomed.txt reapply base main1 X
  record_done 1790000200 || fail 'a newer report of the re-applied deletion was refused'
  [ "$(fm_dod_local_done_head "$META")" = "$Y" ] || fail 'the re-applied deletion did not replace the head'
  assert_deletion_refused 'unconfirmed re-applied deletion'
  assert_contains "$LAST_OUT" '--confirm-deletion doomed.txt' 'the refusal did not offer the confirmation'
  LAST_OUT=$(land_confirming --confirm-deletion doomed.txt 2>&1) || fail "confirmed re-applied deletion refused: $LAST_OUT"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$Y" ] || fail 'the confirmed deletion did not land the re-applied head'
  [ ! -e "$PROJ/doomed.txt" ] || fail 'the confirmed deletion kept the file'
  pass 'a re-application that deletes a path main has replaces the head, then lands only once the deletion is confirmed'
}

test_reapplication_without_a_movable_record_refuses() {
  local out rc
  make_ledger_case reapplied-stampless
  printf 'local_done_head=%s\n' "$X" >> "$META"
  main_ledger base main1
  reapply base main1 X
  record_done 1790000200 >/dev/null 2>&1 && fail 'a stampless record moved to a re-application'
  assert_head_kept stampless
  assert_refused

  make_ledger_case reapplied-no-head
  main_ledger base main1
  reapply base main1 X
  assert_refused

  make_ledger_case reapplied-already-on-main
  record_done 1790000100 || fail 'first ready report was not accepted'
  printf 'approved X\n' > "$PROJ/approved.txt"
  write_ledger "$PROJ" base main1 X
  git -C "$PROJ" add approved.txt ledger.json
  git -C "$PROJ" commit -q -m 'the same change lands another way'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" reset -q --hard main
  record_done 1790000200 >/dev/null 2>&1 && fail 'a report whose content is already on main replaced the record'
  assert_head_kept already-on-main
  rc=0
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "already-on-main: landing succeeded: $out"
  assert_no_record_violation
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'already-on-main: refusal moved main'
  # The change only removes a row main replaced, so main already holds it and a
  # branch at main passes every line check; only its equal tree refuses.
  make_ledger_case reapplied-absorbed
  write_ledger "$PROJ" base a b
  git -C "$PROJ" commit -q -am 'main adds rows a and b'
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" reset -q --hard main
  write_ledger "$WT" base b
  git -C "$WT" commit -q -am 'X drops row a'
  X=$(git -C "$WT" rev-parse HEAD)
  record_done 1790000100 || fail 'absorbed: first ready report was not accepted'
  main_ledger base a2 b
  git -C "$WT" reset -q --hard main
  Y=$BASE
  assert_conflicting_reapplication absorbed "$X"
  record_done 1790000200 >/dev/null 2>&1 && fail 'absorbed: a branch at main replaced the record'
  assert_head_kept absorbed
  rc=0
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "absorbed: landing succeeded: $out"
  assert_no_record_violation
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'absorbed: refusal moved main'
  pass 'a stampless record, a task with no head, or a report whose content main already has never takes a re-application'
}

test_newer_report_of_already_landed_rebase() {
  local replay newer out rc=0
  make_case already-landed-rebase
  record_done || fail 'initial report refused'
  replay=$(git -C "$PROJ" -c user.email=t@t -c user.name=t commit-tree "$X^{tree}" -p main -m replay)
  git -C "$PROJ" merge -q --ff-only "$replay"
  printf 'other lane\n' > "$PROJ/other.txt"
  git -C "$PROJ" add other.txt
  git -C "$PROJ" commit -q -m later
  git -C "$WT" rebase --reapply-cherry-picks --empty=keep main >/dev/null 2>&1 || fail 'landed rebase failed'
  newer=$(git -C "$WT" rev-parse HEAD)
  [ "$newer" != "$X" ] || fail 'landed rebase did not rewrite head'
  record_done 1790000001 || fail 'fresh report could not refresh already-landed content'
  [ "$(fm_dod_local_done_head "$META")" = "$newer" ] || fail 'fresh report did not record rewritten head'
  out=$(land 2>&1) || rc=$?
  # No task changes remain to land; a no-op commit may fast-forward normally.
  if [ "$rc" -ne 0 ]; then
    assert_contains "$out" 'already on main' 'already-landed report reached the wrong refusal'
  fi
  [ "$(cat "$PROJ/other.txt")" = 'other lane' ] || fail 'readiness or landing lost another lane'
  pass 'newer report refreshes a rebased head whose changed paths already landed under other names'
}

# Runs last: every refused landing above left its task record byte-identical.
test_no_refused_landing_changed_its_record() {
  assert_no_record_violation
  pass 'every refused landing in this suite left its task record byte-identical'
}

fm_test_run test_newer_report_of_already_landed_rebase test_two_tasks_cannot_undo_a_same_tree_landing test_branch_advance_does_not_change_approval \
  test_missing_and_malformed_head_refuse test_refused_then_accepted_landing_keeps_whole_record \
  test_change_after_hold_check_refuses \
  test_diverged_default_refuses test_change_during_approval_check_refuses \
  test_snapshot_cannot_pin_a_replacement_task test_done_recording_preserves_caller_locks \
  test_rebased_same_change_replaces_recorded_head test_rereading_a_bound_report_cannot_take_a_rebase \
  test_rebased_revision_or_unbranched_head_refuses \
  test_stale_commit_name_lands_rebased_branch test_content_equal_branch_lands \
  test_differing_tree_refuses_after_main_moves test_conflicting_change_refuses_after_main_moves \
  test_uncommitted_work_refuses_after_main_moves test_already_landed_content_not_landed_twice \
  test_merge_history_refuses_after_main_moves test_missing_recorded_commit_refuses \
  test_landing_that_drops_landed_files_refuses_by_name test_deliberate_deletion_lands_when_confirmed \
  test_content_equal_rebase_with_deletion_needs_confirmation test_bad_confirmation_arguments_refuse \
  test_branch_actor_is_refused_by_the_tool \
  test_newer_report_of_continued_branch_replaces_head test_two_commit_change_is_never_half_landed \
  test_rereading_a_bound_report_cannot_take_later_work test_newer_report_with_changed_tree_refuses \
  test_newer_report_off_fast_forward_refuses test_missing_record_or_report_refuses \
  test_newer_report_of_reapplied_change_replaces_head test_newer_report_of_reapplication_refusals \
  test_reapplied_binary_conflict_refuses test_reapplied_deletion_needs_confirmation \
  test_reapplication_without_a_movable_record_refuses \
  test_no_refused_landing_changed_its_record

#!/usr/bin/env bash
# The idle-fleet queued-work wake through the real watcher and the shared
# supervision-need predicate: a home with no task lane and a ready backlog item
# wakes once after a grace and then only on a long cadence, while an empty
# queue, any lane (live or parked holding a finished result), and the away and
# quiet postures stay as they were. Needs tasks-axi; no endpoint or model call.
set -eu

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# A missing tasks-axi must not shrink this suite to a passing one-line plan: the
# check under test reads its ready list, so without it nothing is proven.
command -v tasks-axi >/dev/null 2>&1 \
  || fail "tasks-axi is required: the idle-fleet check reads its ready list, so this suite proves nothing without it"

TMP_ROOT=$(fm_test_tmproot fm-watch-idle-queue)
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
REASON_PREFIX='check: idle fleet with queued work: '

# Every child this suite runs gets only the environment named here, so whoever
# calls the suite cannot change what the watcher, drain, or backlog read: a
# supervision role (FM_SUPERVISION_ACTOR=branch makes a drain acknowledge
# nothing), a live FM_HOME, or any *_OVERRIDE. The two harness seams the shared
# test helpers install are passed through explicitly.
clean() {  # [VAR=value...] <command> [args...]
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=C \
    FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_WEDGE_ALARM_EXEC="$FM_WEDGE_ALARM_EXEC" "$@"
}

make_home() {  # <name> -> prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  fm_test_tasks_toml "$home/.tasks.toml"
  # The heartbeat is not under test; a fresh schedule keeps it from firing.
  touch "$home/state/.last-heartbeat"
  printf '%s\n' "$home"
}

add_item() {  # <home> <id>
  clean FM_HOME="$1" "$TASKS_AXI" add "$2" "queued work $2" --repo demo >/dev/null 2>&1 \
    || fail "could not add backlog item $2"
}

hold_item() {  # <home> <id>
  clean FM_HOME="$1" "$TASKS_AXI" hold "$2" --reason "waiting on the captain" >/dev/null 2>&1 \
    || fail "could not hold backlog item $2"
}

# Start the real watcher for <home> with tight cadences and a zero grace unless
# the caller overrides one; WATCH_PID names it.
start_watch() {  # <home> <out> [env assignments...]
  local home=$1 out=$2
  shift 2
  fm_test_track_watcher_state "$home/state"
  clean FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_QUEUE_CHECK_SECS=1 FM_IDLE_QUEUE_GRACE_SECS=0 "$@" \
    "$ROOT/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  WATCH_PID=$!
}

stop_watch() {  # <home>
  clean FM_HOME="$1" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  wait "$WATCH_PID" 2>/dev/null || true
}

idle_rows() {  # <home> -> number of queued idle-fleet rows
  awk -F '\t' '$3 == "check" && $4 == "idle-queue"' "$1/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}

# Drain and acknowledge <home>'s queue exactly as main would, so the next cycle
# starts settled instead of resurfacing this one; the drain's printed
# acknowledgement is the only sequence acknowledged.
ack_cycle() {  # <home>
  local home=$1 err="$1/drain.err" sequence generation
  clean FM_HOME="$home" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  clean FM_HOME="$home" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

# Count the cycle's idle-fleet rows into IDLE_WAKES, then settle the queue.
IDLE_WAKES=0
settle() {  # <home>
  IDLE_WAKES=$((IDLE_WAKES + $(idle_rows "$1")))
  ack_cycle "$1" || fail "could not acknowledge the finished cycle's queue: $(cat "$1/drain.err" 2>/dev/null)"
}

# 0 once the watcher exited by itself within the budget.
wait_exit() {  # [ticks]
  local i=0 limit=${1:-150}
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || { wait "$WATCH_PID" 2>/dev/null || true; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Run one watcher that must wake on the idle-fleet check.
expect_idle_wake() {  # <home> <label> [env assignments...]
  local home=$1 label=$2 out
  shift 2
  out="$home/watch-$label.out"
  start_watch "$home" "$out" "$@"
  wait_exit || { stop_watch "$home"; fail "$label: the watcher did not wake on an idle fleet with queued work"; }
  grep -F "$REASON_PREFIX" "$out" >/dev/null \
    || fail "$label: the watcher woke for something else: $(cat "$out" "$out.err")"
  settle "$home"
}

# Run one watcher through one whole poll cycle, which runs the idle-fleet check
# with FM_IDLE_QUEUE_CHECK_SECS=1, and require that it did not wake on it, then
# stop it. A watcher that exits before completing that cycle proves nothing, so
# it fails instead of passing vacuously.
expect_no_idle_wake() {  # <home> <label> [env assignments...]
  local home=$1 label=$2 out
  shift 2
  out="$home/watch-$label.out"
  start_watch "$home" "$out" "$@"
  if ! wait_poll_cycle "$home/state" "$WATCH_PID"; then
    stop_watch "$home"
    fail "$label: the watcher exited before a whole poll cycle: $(cat "$out" "$out.err")"
  fi
  stop_watch "$home"
  if grep -F "$REASON_PREFIX" "$out" >/dev/null 2>&1 || [ "$(idle_rows "$home")" != 0 ]; then
    fail "$label: the idle-fleet check woke: $(cat "$out")"
  fi
  settle "$home"
}

# shellcheck disable=SC2016 # Expanded by the inner bash.
needed() {  # <home> -> "<needed> <ready count>" from the shared supervision-need predicate
  clean bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$2/state"
    printf "%s %s\n" "$FM_SUP_NEEDED" "$FM_SUP_READY_QUEUED"
  ' _ "$ROOT" "$1"
}

test_idle_fleet_with_queued_work_wakes() {
  local home reason
  home=$(make_home idle)
  IDLE_WAKES=0
  add_item "$home" job-a
  add_item "$home" job-b
  [ "$(needed "$home")" = "true 2" ] \
    || fail "the supervision-need predicate did not keep a watcher armed for ready work: $(needed "$home")"
  expect_idle_wake "$home" idle
  reason=$(grep -F "$REASON_PREFIX" "$home/watch-idle.out")
  assert_contains "$reason" '2 ready backlog item(s) and no task lane' "the wake names the ready count"
  [ "$IDLE_WAKES" = 1 ] || fail "the wake was not queued durably exactly once ($IDLE_WAKES)"
  pass "an idle fleet with ready queued work wakes once and keeps supervision armed"
}

test_empty_queue_stays_silent() {
  local home
  home=$(make_home empty)
  [ "$(needed "$home")" = "false 0" ] \
    || fail "an empty backlog counted as supervision need: $(needed "$home")"
  add_item "$home" job-held
  hold_item "$home" job-held
  [ "$(needed "$home")" = "false 0" ] \
    || fail "held-only work still counted as supervision need: $(needed "$home")"
  expect_no_idle_wake "$home" held-only
  [ ! -e "$home/state/.idle-queue-since" ] || fail "an empty ready list left an idle episode open"
  pass "a genuinely empty or fully held queue neither wakes nor needs supervision"
}

test_parked_finished_lane_is_not_a_stall() {
  local home
  home=$(make_home parked)
  add_item "$home" job-next
  fm_write_meta "$home/state/lane.meta" kind=ship mode=no-mistakes yolo=off
  printf 'done [at=1000]: ready in https://example.invalid/pr/1\npaused [at=1001]: parked for review\n' \
    > "$home/state/lane.status"
  printf '%s' "$(seen_sig "$home/state/lane.status")" > "$home/state/.seen-lane_status"
  expect_no_idle_wake "$home" parked
  # The lane is what kept it quiet: once it is cleaned up the same queue counts.
  rm -f "$home/state/lane.meta"
  [ "$(needed "$home")" = "true 1" ] \
    || fail "the parked case was vacuous: without the lane the queue still did not count: $(needed "$home")"
  pass "a parked lane holding a finished result is a deliberate state, not an idle-fleet stall"
}

test_secondmate_is_not_a_task_lane() {
  local home
  home=$(make_home mate)
  add_item "$home" job-main
  fm_write_secondmate_meta "$home/state/mate.meta" "$TMP_ROOT/mate-home"
  expect_idle_wake "$home" mate
  pass "an idle persistent secondmate does not hide ready work in its parent's queue"
}

test_away_and_quiet_postures_unchanged() {
  local home mode
  for mode in away quiet; do
    home=$(make_home "posture-$mode")
    add_item "$home" job-x
    printf '%s\n' "$mode" > "$home/state/.afk"
    [ "$(needed "$home")" = "false 0" ] \
      || fail "$mode posture changed the supervision-need answer: $(needed "$home")"
    expect_no_idle_wake "$home" "$mode"
    # The posture is what kept it quiet: once it ends the same queue counts.
    rm -f "$home/state/.afk"
    [ "$(needed "$home")" = "true 1" ] \
      || fail "the $mode case was vacuous: without the posture the queue still did not count: $(needed "$home")"
  done
  pass "away and quiet postures keep their existing supervision need and wakes"
}

test_repeat_is_bounded() {
  local home past
  home=$(make_home repeat)
  IDLE_WAKES=0
  add_item "$home" job-r
  # Inside the grace the first sighting only opens the episode.
  expect_no_idle_wake "$home" in-grace FM_IDLE_QUEUE_GRACE_SECS=3600
  [ -e "$home/state/.idle-queue-since" ] || fail "the first sighting did not open an idle episode"
  expect_idle_wake "$home" first
  # The backlog is re-read every poll, yet a fresh wake does not repeat.
  expect_no_idle_wake "$home" repoll
  [ "$IDLE_WAKES" = 1 ] || fail "the idle-fleet wake repeated per poll ($IDLE_WAKES)"
  past=$(( $(date +%s) - 14400 - 60 ))
  fm_touch_epoch "$past" "$home/state/.idle-queue-woken"
  expect_idle_wake "$home" resurfaced
  [ "$IDLE_WAKES" = 2 ] || fail "the long-cadence repeat did not queue exactly one more wake ($IDLE_WAKES)"
  pass "the idle-fleet wake waits out its grace and repeats only on its long cadence"
}

fm_test_run \
  test_idle_fleet_with_queued_work_wakes \
  test_empty_queue_stays_silent \
  test_parked_finished_lane_is_not_a_stall \
  test_secondmate_is_not_a_task_lane \
  test_away_and_quiet_postures_unchanged \
  test_repeat_is_bounded

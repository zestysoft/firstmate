# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

FM_SUPERVISION_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_READY_QUEUED   fm_idle_fleet_ready_count below, read only when
#                         nothing else needs supervision (0 otherwise)
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         a registered custom check, or an idle fleet with
#                         ready queued work (FM_SUP_READY_QUEUED above 0), so
#                         the one watcher cycle stays armed to report it
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi
  FM_SUP_READY_QUEUED=0
  if [ "$FM_SUP_NEEDED" = false ]; then
    FM_SUP_READY_QUEUED=$(fm_idle_fleet_ready_count "$state")
    [ "$FM_SUP_READY_QUEUED" -eq 0 ] || FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_idle_fleet_ready_count <state-dir>
# Prints how many backlog items `tasks-axi ready` lists as dispatchable now
# when the fleet is idle, and 0 otherwise. Idle means no task lane: no
# state/*.meta other than a persistent secondmate's. A lane, live or parked
# holding a finished result, already has its own supervision or is a state
# firstmate chose, so it is never a stall here. An away or quiet record
# (state/.afk, either posture) also prints 0, leaving those postures unchanged.
# The backlog is the one this home's layout names: data/ beside <state-dir>, or
# FM_DATA_OVERRIDE, with config/backlog-backend from FM_CONFIG_OVERRIDE or
# config/ beside it, read through bin/fm-tasks-axi.sh under a
# FM_IDLE_QUEUE_READ_TIMEOUT bound (default 10s). A manual backend, a missing
# tasks-axi, a missing data directory, or a read that fails or times out prints
# 0: those homes keep today's behavior, and backlog health has other owners.
fm_idle_fleet_ready_count() {
  local state=$1 meta home data out count bound=${FM_IDLE_QUEUE_READ_TIMEOUT:-10}
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ -e "$state/.afk" ]; then
    echo 0
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null && continue
    echo 0
    return 0
  done
  home=$(cd "$state/.." 2>/dev/null && pwd) || { echo 0; return 0; }
  data=${FM_DATA_OVERRIDE:-$home/data}
  if [ ! -d "$data" ] || ! command -v tasks-axi >/dev/null 2>&1 \
    || [ "$(tr -d '[:space:]' 2>/dev/null < "${FM_CONFIG_OVERRIDE:-$home/config}/backlog-backend")" = manual ]; then
    echo 0
    return 0
  fi
  if ! command -v fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$FM_SUPERVISION_LIB_DIR/fm-timeout-lib.sh"
  fi
  out=$(FM_HOME=$home FM_DATA_OVERRIDE=$data \
    fm_run_timed "$bound" "$FM_SUPERVISION_LIB_DIR/fm-tasks-axi.sh" ready 2>/dev/null </dev/null) \
    || { echo 0; return 0; }
  count=$(printf '%s\n' "$out" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p' | head -1)
  echo "${count:-0}"
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

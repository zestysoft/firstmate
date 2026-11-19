#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id> [backend]
#   fm_remote_runtime_gate / fm_remote_runtime_record_refusal (see "worker
#   runtime version gap" below)
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix --automatic
# and then a third read-only time. --automatic is what makes this unattended
# repair safe on a shared host: it never stops, reloads, replaces, or takes over
# a running Herdr server or a loaded Herdr launch agent, and leaves those
# repairs to an operator's explicit --fix. That last read-only run is the
# verdict, so a repair is never trusted on its own word. bin/fm-remote-doctor.sh
# remains the single owner of every check, every repair, and every message;
# nothing here restates them.
#
# <backend> is herdr, rex, or any (the default). A concrete backend is passed
# to the doctor's --backend flag; `any` invokes it bare, which resolves
# whichever supported backend that host provides. A remote still on the
# herdr-only doctor exits 2 on the unknown flag; an explicit herdr request then
# retries its read-only checks bare, whose only selectable backend there is
# herdr. rex has no such fallback: a remote that old cannot run it. The repair
# never retries without --automatic, so a remote too old to repair safely is
# reported not ready instead of repaired the unsafe way.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_probe() { # <bin-dir> <secondmate-id> [doctor-args...]
  local bin_dir=$1 id=$2 out rc
  shift 2
  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh "$@" </dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  return "$rc"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id> [backend]
  local bin_dir=$1 id=$2 backend=${3:-any} rc
  local -a doctor_args=()
  [ "$backend" = any ] || doctor_args=(--backend "$backend")

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    # A remote still on the herdr-only doctor refuses the flag entirely; bare
    # is the same request there.
    fm_remote_readiness_probe "$bin_dir" "$id"
    rc=$?
  fi
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" --fix --automatic ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  [ "$rc" -ne 255 ] || return 255

  fm_remote_readiness_probe "$bin_dir" "$id" ${doctor_args[@]+"${doctor_args[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "$backend" = herdr ]; then
    fm_remote_readiness_probe "$bin_dir" "$id"
    rc=$?
  fi
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# --- worker runtime version gap ---------------------------------------------
#
# The doctor above proves the host can hold a durable endpoint, not that the
# worker runtime on it can load this home's extensions: a runtime too old for
# them passes every check and then exits at launch. These two functions name
# that gap instead, and keep recovery from respawning into it.
#
#   fm_remote_runtime_gate <bin-dir> <state-dir> <secondmate-id> <host> <harness>
#       Read <harness>'s version here and on the host (the host's
#       fm-remote-secondmate-control.sh runtime-version verb, so call it after
#       the pre-launch sync), and set FM_REMOTE_RUNTIME_HOME_VERSION,
#       FM_REMOTE_RUNTIME_HOST_VERSION, FM_REMOTE_RUNTIME_RELATION (the host's
#       version relative to this home's: older, newer, same, or unknown), and
#       FM_REMOTE_RUNTIME_LINE, a sentence saying which side is older when the
#       two known versions differ (empty otherwise). A difference alone never
#       refuses. It returns 1, with FM_REMOTE_RUNTIME_REFUSAL set, only while
#       <state-dir>/.remote-runtime-refusal-<id> records an earlier launch on
#       this same host and harness that exited on an older host runtime and the
#       host still reports that version, or cannot report one. A changed host
#       version removes the record and returns 0.
#   fm_remote_runtime_record_refusal <state-dir> <secondmate-id> <host> <harness> <host-version> <exit-line>
#       After a launch whose agent exited at once, write that record when
#       <host-version> is older than FM_REMOTE_RUNTIME_HOME_VERSION (set by the
#       gate) and return 0 with FM_REMOTE_RUNTIME_REFUSAL set; otherwise return
#       1 and write nothing. Neither function touches the mate's home, work, or
#       endpoint.
FM_REMOTE_RUNTIME_HOME_VERSION=
FM_REMOTE_RUNTIME_HOST_VERSION=
FM_REMOTE_RUNTIME_RELATION=unknown
FM_REMOTE_RUNTIME_LINE=
FM_REMOTE_RUNTIME_REFUSAL=

# shellcheck source=bin/fm-runtime-version-lib.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/fm-runtime-version-lib.sh"

fm_remote_runtime_gap_text() { # <host> <harness> <host-version> <home-version>
  printf "host %s runs %s %s, older than this home's %s %s; upgrade %s on %s to %s or newer, then respawn the mate (its home and work were left untouched)" \
    "$1" "$2" "$3" "$2" "$4" "$2" "$1" "$4"
}

fm_remote_runtime_gate() { # <bin-dir> <state-dir> <secondmate-id> <host> <harness>
  local bin_dir=$1 state=$2 id=$3 host=$4 harness=$5 out marker
  local rec_host rec_harness rec_version rec_home rec_line
  FM_REMOTE_RUNTIME_HOME_VERSION=$(fm_runtime_version "$harness")
  FM_REMOTE_RUNTIME_HOST_VERSION=
  FM_REMOTE_RUNTIME_LINE=
  FM_REMOTE_RUNTIME_REFUSAL=
  if out=$("$bin_dir/fm-on.sh" "$id" fm-remote-secondmate-control.sh runtime-version "$id" "$harness" </dev/null 2>/dev/null); then
    FM_REMOTE_RUNTIME_HOST_VERSION=$(printf '%s\n' "$out" | sed -n 's/^runtime_version=//p' | tail -1)
  fi
  FM_REMOTE_RUNTIME_RELATION=$(fm_runtime_version_compare "$FM_REMOTE_RUNTIME_HOST_VERSION" "$FM_REMOTE_RUNTIME_HOME_VERSION")
  case "$FM_REMOTE_RUNTIME_RELATION" in
    older) FM_REMOTE_RUNTIME_LINE="host $host runs $harness $FM_REMOTE_RUNTIME_HOST_VERSION, older than this home's $FM_REMOTE_RUNTIME_HOME_VERSION" ;;
    newer) FM_REMOTE_RUNTIME_LINE="this home runs $harness $FM_REMOTE_RUNTIME_HOME_VERSION, older than host $host's $FM_REMOTE_RUNTIME_HOST_VERSION" ;;
  esac
  marker="$state/.remote-runtime-refusal-$id"
  [ -f "$marker" ] || return 0
  rec_host=$(sed -n 's/^host=//p' "$marker" | tail -1)
  rec_harness=$(sed -n 's/^harness=//p' "$marker" | tail -1)
  rec_version=$(sed -n 's/^host_version=//p' "$marker" | tail -1)
  rec_home=$(sed -n 's/^home_version=//p' "$marker" | tail -1)
  rec_line=$(sed -n 's/^exit_line=//p' "$marker" | tail -1)
  if [ "$rec_host" != "$host" ] || [ "$rec_harness" != "$harness" ] ||
    { [ -n "$FM_REMOTE_RUNTIME_HOST_VERSION" ] && [ "$FM_REMOTE_RUNTIME_HOST_VERSION" != "$rec_version" ]; }; then
    rm -f -- "$marker"
    return 0
  fi
  FM_REMOTE_RUNTIME_REFUSAL="remote secondmate $id was not relaunched: its last launch exited at once (${rec_line:-no output}), and $(fm_remote_runtime_gap_text "$host" "$harness" "$rec_version" "$rec_home")"
  [ -n "$FM_REMOTE_RUNTIME_HOST_VERSION" ] ||
    FM_REMOTE_RUNTIME_REFUSAL="$FM_REMOTE_RUNTIME_REFUSAL; the host's current $harness version could not be read"
  return 1
}

fm_remote_runtime_record_refusal() { # <state-dir> <secondmate-id> <host> <harness> <host-version> <exit-line>
  local state=$1 id=$2 host=$3 harness=$4 host_version=$5 line=$6 marker tmp
  [ "$(fm_runtime_version_compare "$host_version" "$FM_REMOTE_RUNTIME_HOME_VERSION")" = older ] || return 1
  marker="$state/.remote-runtime-refusal-$id"
  tmp="$marker.tmp.$$"
  if ! {
    printf 'at=%s\n' "$(date +%s)"
    printf 'host=%s\n' "$host"
    printf 'harness=%s\n' "$harness"
    printf 'host_version=%s\n' "$host_version"
    printf 'home_version=%s\n' "$FM_REMOTE_RUNTIME_HOME_VERSION"
    printf 'exit_line=%s\n' "$line"
  } > "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_REMOTE_RUNTIME_REFUSAL="remote secondmate $id exited at launch on $host (${line:-no output}): $(fm_remote_runtime_gap_text "$host" "$harness" "$host_version" "$FM_REMOTE_RUNTIME_HOME_VERSION"); relaunches stay refused until that version changes"
  return 0
}

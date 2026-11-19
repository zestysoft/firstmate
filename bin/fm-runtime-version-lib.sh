#!/usr/bin/env bash
# fm-runtime-version-lib.sh - read and compare a worker runtime's version.
#
# Source this file and call:
#   fm_runtime_version <harness>
#       Print the dotted version (for example 0.87.1) that the harness's own
#       executable on this PATH reports for `--version`, or nothing when the
#       executable is absent, the call fails or times out, or no dotted version
#       appears in its output. The executable is the harness name itself, which
#       is how bin/fm-spawn.sh resolves every harness a remote second mate can
#       run except cursor, whose CLI has its own resolver and reads as unknown
#       here. The call is bounded by FM_RUNTIME_VERSION_TIMEOUT seconds
#       (default 10) and never reads stdin.
#   fm_runtime_version_compare <a> <b>
#       Print older, newer, or same for version <a> relative to <b>, comparing
#       dot-separated numeric fields left to right with missing fields read as
#       zero, or unknown when either side is empty or not purely numeric.
#
# Remote second-mate launch uses the pair to tell an operator which side of a
# host/home runtime gap is behind (bin/fm-remote-readiness-lib.sh owns that).

FM_RUNTIME_VERSION_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_RUNTIME_VERSION_LIB_DIR/fm-timeout-lib.sh"

fm_runtime_version() { # <harness>
  local harness=$1 bin out
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|omp) ;;
    *) return 0 ;;
  esac
  bin=$(type -P -- "$harness" 2>/dev/null) || return 0
  [ -x "$bin" ] || return 0
  out=$(fm_run_timed "${FM_RUNTIME_VERSION_TIMEOUT:-10}" "$bin" --version </dev/null 2>/dev/null) || return 0
  printf '%s\n' "$out" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1
}

fm_runtime_version_compare() { # <a> <b>
  local a=$1 b=$2 fa fb
  case "$a" in ''|*[!0-9.]*|.*|*.|*..*) printf 'unknown\n'; return 0 ;; esac
  case "$b" in ''|*[!0-9.]*|.*|*.|*..*) printf 'unknown\n'; return 0 ;; esac
  while [ -n "$a" ] || [ -n "$b" ]; do
    fa=${a%%.*}
    fb=${b%%.*}
    [ -n "$fa" ] || fa=0
    [ -n "$fb" ] || fb=0
    # Strip leading zeros so a field never reads as octal.
    fa=$((10#$fa))
    fb=$((10#$fb))
    if [ "$fa" -lt "$fb" ]; then printf 'older\n'; return 0; fi
    if [ "$fa" -gt "$fb" ]; then printf 'newer\n'; return 0; fi
    case "$a" in *.*) a=${a#*.} ;; *) a= ;; esac
    case "$b" in *.*) b=${b#*.} ;; *) b= ;; esac
  done
  printf 'same\n'
}

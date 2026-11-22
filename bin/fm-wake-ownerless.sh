#!/usr/bin/env bash
# fm-wake-ownerless.sh - decide whether a watcher wake reason names only
# subjects that no task record owns any more.
#
# Usage: fm-wake-ownerless.sh '<wake reason line>'
#
# Exit 0  every subject of a `signal:` or `stale:` reason is ownerless: no
#         `<id>.meta` in the state directory for a status or turn-end file, and
#         no meta whose window= or terminal= names the stale window. One line
#         is appended to state/.watch-triage.log saying so.
# Exit 1  anything else, including a reason of any other class, a reason with
#         at least one owned subject, a subject this script cannot parse, or any
#         doubt. The caller delivers the wake unchanged.
# Exit 2  usage error.
#
# Why it exists: a primary-watcher bridge can hand wakes to its model later
# than the watcher printed them (the Pi bridge delivers one per model turn
# while main is idle, because Pi's sendUserMessage resolves only when that
# whole run settles). By then the supervisor may already have drained the
# queued rows and cleaned the worker up, so the late text names a status log or
# window with no record behind it. Only a definite "no owner for every
# subject" suppresses; a wake that names any live record is never touched.
# The state directory follows FM_STATE_OVERRIDE, then FM_HOME/state.

set -u

FM_WAKE_OWNERLESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-push-transition-lib.sh
. "$FM_WAKE_OWNERLESS_DIR/fm-push-transition-lib.sh"

[ "$#" -eq 1 ] || { echo "usage: $(basename "$0") '<wake reason line>'" >&2; exit 2; }

reason=${1%%$'\n'*}
[ -d "$STATE" ] || exit 1

subject_ownerless() {  # <class> <subject>
  local class=$1 subject=$2 id
  case "$class" in
    signal)
      case "$subject" in
        */*) [ "${subject%/*}" = "$STATE" ] || return 1 ;;
      esac
      id=${subject##*/}
      case "$id" in
        *.status) id=${id%.status} ;;
        *.turn-ended) id=${id%.turn-ended} ;;
        *) return 1 ;;
      esac
      [ -n "$id" ] || return 1
      [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]
      ;;
    stale)
      [ -n "$subject" ] || return 1
      ! fm_backend_meta_for_window "$subject" "$STATE" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

case "$reason" in
  'signal: '*)
    class=signal
    subjects=${reason#signal: }
    ;;
  'stale: '*)
    class=stale
    subjects=${reason#stale: }
    subjects=${subjects%% *}
    ;;
  *) exit 1 ;;
esac

# Split on whitespace only: subjects are paths and window ids, never globs.
set -f
# shellcheck disable=SC2086  # deliberate word split of the subject list
set -- $subjects
set +f
[ "$#" -gt 0 ] || exit 1
for subject in "$@"; do
  subject_ownerless "$class" "$subject" || exit 1
done

triage_log "absorbed late $class wake at delivery (no task record owns any subject): $reason"
exit 0

#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to local_done_head= in state/<task-id>.meta,
# recorded when the done report was accepted by bin/fm-dod-lib.sh, whose
# fm_dod_pin_local_done_head owns when a later report may move it. Missing or
# malformed heads refuse. Legacy tasks with no head must report readiness again
# before approval.
# While the default branch is still an ancestor of the recorded head, only that
# exact commit lands and the recorded ship branch must still point at it.
# Once the default branch has moved past the point the recorded head can
# fast-forward, the approval is held by content instead of by commit name: the
# recorded head's change is three-way merged onto the current default branch
# with git merge-tree (Git 2.38 or newer), and the ship branch's current tip
# lands when it is a linear (merge-free) fast-forward of the default branch
# whose tree equals that merge result. A conflicting merge, a missing recorded
# commit, a branch tree that differs, or merge commits above the default branch
# refuse; a resolved conflict is new content that needs a newer readiness
# report to re-record the head.
# A merge result equal to the default branch's own tree means the change is
# already there, so it refuses rather than landing the same content twice.
# Either way, a landing that would remove any path the default branch has
# refuses and names those paths. Git history cannot tell a deliberate deletion
# from a commit whose content came from an older base and so drops files a
# landed commit added, so the operator states it: retry with one
# --confirm-deletion <path> for every named path. Confirmations must name
# exactly the paths the landing removes; a missing or extra one refuses.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward. A diverged branch needs a
# rebase onto the default branch before landing. A newer ready report may then
# re-record the head; fm_dod_pin_local_done_head in bin/fm-dod-lib.sh owns which
# heads qualify (a rebase of the same change, a continuation of the recorded
# content, or a re-application through a resolved conflict that fast-forwards
# the default branch). A re-recorded head lands by the same rules as any
# recorded head. Without a newer report, the content check above lands a rebase
# whose tree matches. Every refusal here leaves the task record untouched.
# Revised work needs a new task/approval record. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# A per-checkout lock in the project's Git directory serializes different
# tasks across the checks, checkout update, ref transaction, and rollback.
# tests/fm-merge-local.test.sh covers pinned-head landing, re-recorded heads,
# content-equal landing after the default branch moved, deletion refusals, and
# race refusals.
# Usage: fm-merge-local.sh <task-id> [--confirm-deletion <path>]...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
CONFIRMED_DELETIONS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm-deletion)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "error: --confirm-deletion needs a path" >&2
        exit 2
      fi
      CONFIRMED_DELETIONS+=("$2")
      shift 2
      ;;
    *)
      echo "error: invalid local merge request" >&2
      exit 2
      ;;
  esac
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
MERGE_EXPECTED_HEAD=$(fm_dod_local_done_head "$META") || {
  echo "error: missing or malformed local done head for task $ID; report readiness before approval" >&2
  exit 1
}

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
MERGE_PROJECT_LOCK=
MERGE_DELETIONS_TMP=
merge_control_cleanup() {
  [ -z "$MERGE_DELETIONS_TMP" ] || rm -f -- "$MERGE_DELETIONS_TMP"
  [ -z "$MERGE_PROJECT_LOCK" ] || fm_lock_release "$MERGE_PROJECT_LOCK" || true
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
MERGE_META_LOCK=$(fm_meta_lock_path "$META")
fm_lock_acquire_wait "$MERGE_META_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi
MERGE_HEAD=$(fm_dod_local_done_head "$META") || {
  echo "error: missing or malformed local done head for task $ID" >&2
  exit 1
}
[ "$MERGE_HEAD" = "$MERGE_EXPECTED_HEAD" ] || {
  echo "error: task $ID local done head changed while waiting to merge; refusing" >&2
  exit 1
}

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
# MERGE_LAND is the commit that lands: the recorded head itself, or a
# content-equal branch tip chosen by content_equal_land_candidate below.
MERGE_LAND=
branch_tip() {
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}"
}
local_head_matches() {
  [ -n "$MERGE_LAND" ] && [ "$(branch_tip)" = "$MERGE_LAND" ]
}
project_git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir) || {
  echo "error: cannot determine the project checkout's Git directory" >&2
  exit 1
}
MERGE_PROJECT_LOCK="$project_git_dir/fm-local-landing.lock"
fm_lock_acquire_wait "$MERGE_PROJECT_LOCK"
git -C "$PROJ" cat-file -e "$MERGE_HEAD^{commit}" 2>/dev/null || {
  echo "error: the recorded local done head $MERGE_HEAD is not a commit in $PROJ; refusing" >&2
  exit 1
}

DEFAULT=$(fm_dod_project_default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

refuse_diverged() {
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT and report ready again, then retry." >&2
  exit 1
}

# The default branch moved past the recorded head, so the head cannot land as
# recorded. Accept the branch tip only when it carries exactly the recorded
# change applied to the current default branch (see the header).
content_equal_land_candidate() {
  local merged merge_status default_tree tip
  merged=$(git -C "$PROJ" merge-tree --write-tree "$before" "$MERGE_HEAD" 2>/dev/null) || {
    merge_status=$?
    if [ "$merge_status" -eq 1 ]; then
      echo "REFUSED: the recorded local done head conflicts with the current $DEFAULT; a resolved rebase is new content that needs a new readiness record and approval." >&2
    else
      echo "error: could not merge the recorded local done head onto $DEFAULT (git merge-tree --write-tree exit $merge_status; Git 2.38 or newer required); refusing" >&2
    fi
    exit 1
  }
  merged=$(printf '%s\n' "$merged" | head -1)
  default_tree=$(git -C "$PROJ" rev-parse --verify "$before^{tree}") || exit 1
  if [ "$merged" = "$default_tree" ]; then
    echo "REFUSED: the recorded change for task $ID is already on $DEFAULT; nothing to land." >&2
    exit 1
  fi
  tip=$(branch_tip) || {
    echo "error: branch $BRANCH is missing; refusing" >&2
    exit 1
  }
  git -C "$PROJ" merge-base --is-ancestor "$before" "$tip" || refuse_diverged
  if [ -n "$(git -C "$PROJ" rev-list --min-parents=2 "$before..$tip")" ]; then
    echo "REFUSED: $BRANCH has merge commits above $DEFAULT; only a linear rebase of the recorded change can land in its place." >&2
    exit 1
  fi
  if [ "$(git -C "$PROJ" rev-parse --verify "$tip^{tree}")" != "$merged" ]; then
    echo "error: branch $BRANCH content differs from the recorded local done head applied to $DEFAULT; refusing" >&2
    exit 1
  fi
  MERGE_LAND=$tip
}

# Clean fast-forward only: DEFAULT must be an ancestor of the landed commit.
before=$(git -C "$PROJ" rev-parse "$DEFAULT")
ancestor_status=0
git -C "$PROJ" merge-base --is-ancestor "$before" "$MERGE_HEAD" || ancestor_status=$?
case "$ancestor_status" in
  0)
    MERGE_LAND=$MERGE_HEAD
    local_head_matches || { echo "error: branch $BRANCH differs from the recorded local done head; refusing" >&2; exit 1; }
    ;;
  1) content_equal_land_candidate ;;
  *)
    echo "error: could not compare $DEFAULT with the recorded local done head; refusing" >&2
    exit 1
    ;;
esac

# Every path the default branch has and the landed commit lacks must be
# confirmed by name (see the header); the operator states it, nothing infers it.
REMOVED_PATHS=()
path_listed() {  # <path> <list...>
  local want=$1 have
  shift
  for have in "$@"; do
    [ "$have" != "$want" ] || return 0
  done
  return 1
}
refuse_unconfirmed_deletions() {
  local path unconfirmed=0 extra=() retry
  MERGE_DELETIONS_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-merge-local-deletions.XXXXXX") || exit 1
  git -C "$PROJ" diff-tree -r -z --no-renames --diff-filter=D --name-only "$before" "$MERGE_LAND" \
    > "$MERGE_DELETIONS_TMP" || {
    echo "error: could not list the paths landing $BRANCH would remove from $DEFAULT; refusing" >&2
    exit 1
  }
  while IFS= read -r -d '' path; do
    REMOVED_PATHS+=("$path")
    path_listed "$path" ${CONFIRMED_DELETIONS[@]+"${CONFIRMED_DELETIONS[@]}"} || unconfirmed=1
  done < "$MERGE_DELETIONS_TMP"
  rm -f -- "$MERGE_DELETIONS_TMP"
  MERGE_DELETIONS_TMP=
  for path in ${CONFIRMED_DELETIONS[@]+"${CONFIRMED_DELETIONS[@]}"}; do
    path_listed "$path" ${REMOVED_PATHS[@]+"${REMOVED_PATHS[@]}"} || extra+=("$path")
  done
  if [ "${#extra[@]}" -gt 0 ]; then
    echo "error: --confirm-deletion names paths landing $BRANCH does not remove from $DEFAULT; refusing:" >&2
    printf '  %q\n' "${extra[@]}" >&2
    exit 1
  fi
  [ "$unconfirmed" -eq 1 ] || return 0
  echo "REFUSED: landing $BRANCH would delete ${#REMOVED_PATHS[@]} path(s) that $DEFAULT has:" >&2
  printf '  %q\n' "${REMOVED_PATHS[@]}" >&2
  echo "If the branch's content came from an older base, these may be files a commit already on $DEFAULT added; have the crewmate restore them and report ready again." >&2
  retry="$SCRIPT_DIR/fm-merge-local.sh $ID"
  for path in "${REMOVED_PATHS[@]}"; do
    retry="$retry --confirm-deletion $(printf '%q' "$path")"
  done
  echo "If the branch deleted them on purpose, state that by retrying with:" >&2
  echo "  $retry" >&2
  exit 1
}
refuse_unconfirmed_deletions

hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
# Recheck after the approval read. Git's ref transaction below verifies and
# locks the worker head together with the default-branch update.
if [ "$(fm_dod_local_done_head "$META")" != "$MERGE_HEAD" ] || ! local_head_matches; then
  echo "error: local done head or branch changed during approval check; refusing" >&2
  exit 1
fi
merge_status=0
# Stage the fast-forward with Git's two-tree checkout, which preserves local
# changes made since the clean-tree check and refuses obstructing files.
git -C "$PROJ" read-tree -m -u "$before" "$MERGE_LAND" || exit $?
git -C "$PROJ" update-ref -m "merge $BRANCH: Fast-forward" --stdin >/dev/null <<EOF || merge_status=$?
start
verify refs/heads/$BRANCH $MERGE_LAND
update refs/heads/$DEFAULT $MERGE_LAND $before
prepare
commit
EOF
if [ "$merge_status" -ne 0 ]; then
  # The transaction left main untouched. Undo only the staged fast-forward;
  # the two-tree checkout also protects any intervening local edits here.
  git -C "$PROJ" read-tree -m -u "$MERGE_LAND" "$before" || {
    echo "error: local merge refused and checkout restoration failed in $PROJ" >&2
    exit 1
  }
fi
fm_lock_release "$MERGE_META_LOCK" || true
MERGE_META_LOCK=
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
fm_lock_release "$MERGE_PROJECT_LOCK" || true
MERGE_PROJECT_LOCK=
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
[ "${#REMOVED_PATHS[@]}" -eq 0 ] \
  || echo "note: landing deleted ${#REMOVED_PATHS[@]} path(s) the operator confirmed as deliberate" >&2
[ "$MERGE_LAND" = "$MERGE_HEAD" ] \
  || echo "note: landed $BRANCH at $MERGE_LAND, whose tree equals recorded done head $MERGE_HEAD applied to $DEFAULT" >&2
# A content-equal landing proves both directions from the landed state: the
# checkout and index are byte-identical to the landed branch tip, and every path
# the default branch had before is still there unless confirmed as deleted.
content_equal_landing_proof() {
  local files before_paths path lost=()
  if [ "$(git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{tree}")" != "$(git -C "$PROJ" rev-parse --verify --quiet "$MERGE_LAND^{tree}")" ] \
    || ! git -C "$PROJ" diff --quiet --no-ext-diff --no-textconv "$MERGE_LAND" -- \
    || ! git -C "$PROJ" diff --cached --quiet --no-ext-diff "$MERGE_LAND" --; then
    echo "error: landed $MERGE_LAND on $DEFAULT, but the checkout in $PROJ is not byte-identical to branch $BRANCH; inspect it before anything else lands" >&2
    return 1
  fi
  files=$(git -C "$PROJ" ls-tree -r -z --name-only "$MERGE_LAND" | tr -cd '\0' | wc -c | tr -d ' ')
  echo "proof: all $files file(s) in the landed $DEFAULT index and checkout are byte-identical to branch $BRANCH at $MERGE_LAND"
  before_paths=$(git -C "$PROJ" ls-tree -r -z --name-only "$before" | tr -cd '\0' | wc -c | tr -d ' ')
  while IFS= read -r -d '' path; do
    path_listed "$path" ${REMOVED_PATHS[@]+"${REMOVED_PATHS[@]}"} || lost+=("$path")
  done < <(git -C "$PROJ" diff-tree -r -z --no-renames --diff-filter=D --name-only "$before" "$DEFAULT")
  if [ "${#lost[@]}" -gt 0 ]; then
    echo "error: landed $MERGE_LAND on $DEFAULT, but ${#lost[@]} path(s) present before the landing are missing:" >&2
    printf '  %q\n' "${lost[@]}" >&2
    return 1
  fi
  echo "proof: all $before_paths path(s) on $DEFAULT before the landing ($before) are present after it except ${#REMOVED_PATHS[@]} confirmed deletion(s); none missing"
}
proof_status=0
[ "$MERGE_LAND" = "$MERGE_HEAD" ] || content_equal_landing_proof || proof_status=$?
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
exit "$proof_status"

#!/usr/bin/env bash
# Live driver part 2: adversarial smuggled-commit case and the readiness gate
# (fm_dod_accept_ship_done, the gate fm-crew-state.sh and fm-inactive-reconcile.sh call)
# after an identical rebase, before landing. Marked disposable lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
trap 'rm -rf "$LAB"' EXIT
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export FM_HOME="$LAB"
. "$ROOT/bin/fm-dod-lib.sh"
P="$LAB/projects/demo"
git init -q -b main "$P"; echo base > "$P/README"; git -C "$P" add .; git -C "$P" commit -qm base
done_line() { printf 'done [at=1790000000]: ready in branch fm/%s' "$1"; }
gate() { echo "\$ fm_dod_accept_ship_done (readiness gate) for $1"; fm_dod_accept_ship_done ship local-only "$LAB/wt-$1" "$P" "$(done_line "$1")" "$LAB/state" "$1" "$LAB/state/$1.meta"; echo "[exit $?]"; }
mklane() {
  git -C "$P" worktree add -q -b "fm/$1" "$LAB/wt-$1" main
  printf '%s\n' "$3" > "$LAB/wt-$1/$2"; git -C "$LAB/wt-$1" add "$2"; git -C "$LAB/wt-$1" commit -qm "$1 work"
  printf 'kind=ship\nmode=local-only\nbranch=fm/%s\nproject=%s\nworktree=%s\nspawn_gen=lab-1\n' "$1" "$P" "$LAB/wt-$1" > "$LAB/state/$1.meta"
  gate "$1" >/dev/null
}
land() { echo "\$ bin/fm-merge-local.sh $1"; bash "$ROOT/bin/fm-merge-local.sh" "$1" 2>&1 | grep -v -i watcher; echo "[exit ${PIPESTATUS[0]}]"; }
head_of() { grep '^local_done_head=' "$LAB/state/$1.meta" | cut -d= -f2; }
mklane d d.txt "lane D approved"; mklane e e.txt "lane E"; land e >/dev/null
rec=$(head_of d); echo "D recorded head=$rec"
echo "=== S4b: identical rebase PLUS an extra unapproved commit on top ==="
git -C "$LAB/wt-d" rebase -q main
echo extra > "$LAB/wt-d/sneaky.txt"; git -C "$LAB/wt-d" add sneaky.txt; git -C "$LAB/wt-d" commit -qm sneaky
m0=$(git -C "$P" rev-parse main)
land d
echo "main unchanged: $([ "$m0" = "$(git -C "$P" rev-parse main)" ] && echo yes || echo NO); record unchanged: $([ "$rec" = "$(head_of d)" ] && echo yes || echo NO); sneaky on main: $(git -C "$P" ls-tree --name-only main sneaky.txt || true)"
echo "=== S5: readiness gate re-reads the lane after an identical rebase, before landing ==="
git -C "$LAB/wt-d" reset -q --hard HEAD~1; echo "D worktree HEAD now identical rebase $(git -C "$LAB/wt-d" rev-parse --short HEAD)"
gate d
echo "record after gate: $(head_of d | cut -c1-8)"
echo "=== S6: after the gate read, the identical rebase still lands ==="
land d
echo "main=$(git -C "$P" rev-parse --short main) files: $(git -C "$P" ls-tree --name-only main | tr '\n' ' ') record=$(head_of d | cut -c1-8)"
echo "=== S5b: readiness gate after landing (record now rebased head) ==="
gate d

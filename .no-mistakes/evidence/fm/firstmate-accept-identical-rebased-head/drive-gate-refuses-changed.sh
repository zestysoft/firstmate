#!/usr/bin/env bash
set -u; ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1; trap 'rm -rf "$LAB"' EXIT
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid FM_HOME="$LAB"; . "$ROOT/bin/fm-dod-lib.sh"
P="$LAB/projects/demo"; git init -q -b main "$P"; echo base > "$P/README"; git -C "$P" add .; git -C "$P" commit -qm base
git -C "$P" worktree add -q -b fm/d "$LAB/wt" main; echo approved > "$LAB/wt/d.txt"; git -C "$LAB/wt" add .; git -C "$LAB/wt" commit -qm d
printf 'kind=ship\nmode=local-only\nbranch=fm/d\nproject=%s\nworktree=%s\nspawn_gen=lab-1\n' "$P" "$LAB/wt" > "$LAB/state/d.meta"
g() { fm_dod_accept_ship_done ship local-only "$LAB/wt" "$P" 'done [at=1790000000]: ready in branch fm/d' "$LAB/state" d "$LAB/state/d.meta"; echo "[gate exit $?]"; }
g; echo other > "$P/o.txt"; git -C "$P" add .; git -C "$P" commit -qm other; git -C "$LAB/wt" rebase -q main
echo "--- identical rebase:"; g
echo "edited" > "$LAB/wt/d.txt"; git -C "$LAB/wt" commit -qa --amend -m d
echo "--- rebase with edited content:"; g

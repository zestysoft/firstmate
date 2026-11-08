#!/usr/bin/env bash
# Live driver: real bin/fm-merge-local.sh + bin/fm-crew-state.sh against a marked
# disposable lab home and throwaway git projects. Three local-only lanes finish together.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
trap 'rm -rf "$LAB"' EXIT
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
. "$ROOT/bin/fm-dod-lib.sh"
P="$LAB/projects/demo"
git init -q -b main "$P"; echo base > "$P/README"; git -C "$P" add .; git -C "$P" commit -qm base
mklane() { # id file content
  git -C "$P" worktree add -q -b "fm/$1" "$LAB/wt-$1" main
  printf '%s\n' "$3" > "$LAB/wt-$1/$2"; git -C "$LAB/wt-$1" add "$2"; git -C "$LAB/wt-$1" commit -qm "$1 work"
  printf 'kind=ship\nmode=local-only\nbranch=fm/%s\nproject=%s\nworktree=%s\nspawn_gen=lab-1\n' "$1" "$P" "$LAB/wt-$1" > "$LAB/state/$1.meta"
  printf 'done [at=1790000000]: ready in branch fm/%s\n' "$1" > "$LAB/state/$1.status"
  fm_dod_accept_ship_done ship local-only "$LAB/wt-$1" "$P" "done [at=1790000000]: ready in branch fm/$1" "$LAB/state" "$1" "$LAB/state/$1.meta" >/dev/null || echo "!! done not accepted for $1"
}
land() { echo "\$ bin/fm-merge-local.sh $1"; bash "$ROOT/bin/fm-merge-local.sh" "$1" 2>&1; echo "[exit $?]"; }
head_of() { grep '^local_done_head=' "$LAB/state/$1.meta" | cut -d= -f2; }
crew() { echo "\$ bin/fm-crew-state.sh $1"; FM_CREW_STATE_NO_FORGE=1 bash "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1 | head -3; }
show() { echo "  main=$(git -C "$P" rev-parse --short main) files: $(git -C "$P" ls-tree --name-only main | tr '\n' ' ')"; }

echo "=== S1/S2: three lanes A,B,C finish together (each recorded done head on old main) ==="
mklane a a.txt "lane A"; mklane b b.txt "lane B"; mklane c c.txt "lane C"
echo "recorded: a=$(head_of a | cut -c1-8) b=$(head_of b | cut -c1-8) c=$(head_of c | cut -c1-8)"
land a; show
echo "--- B not rebased yet: still refused with the rebase hint"
land b; show
echo "--- B rebases onto main (identical content), C also rebases onto main now"
git -C "$LAB/wt-b" rebase -q main; git -C "$LAB/wt-c" rebase -q main
echo "B rebased head=$(git -C "$LAB/wt-b" rev-parse --short HEAD)"
echo "--- S5 readiness gate view between rebase and landing:"
crew b
land b; show; echo "B record now: $(head_of b | cut -c1-8)"
echo "--- S3: C rebased onto A only; B landed since. C retries:"
land c; show; echo "C record still: $(head_of c | cut -c1-8)"
git -C "$LAB/wt-c" rebase -q main; echo "C rebased again head=$(git -C "$LAB/wt-c" rev-parse --short HEAD)"
land c; show; echo "C record now: $(head_of c | cut -c1-8)"
for f in a b c; do echo "  main:$f.txt = $(git -C "$P" show main:$f.txt)"; done
echo "  checkout clean: [$(git -C "$P" status --porcelain)]"

echo "=== S4 adversarial: rebased lane smuggles different content ==="
mklane d d.txt "lane D approved"; mklane e e.txt "lane E"; land e >/dev/null
git -C "$LAB/wt-d" rebase -q main
printf 'lane D EDITED after approval\n' > "$LAB/wt-d/d.txt"; git -C "$LAB/wt-d" commit -qa --amend -m "d work"
before=$(git -C "$P" rev-parse --short main); rec=$(head_of d)
land d; show; echo "main unchanged: $([ "$before" = "$(git -C "$P" rev-parse --short main)" ] && echo yes || echo NO)  record unchanged: $([ "$rec" = "$(head_of d)" ] && echo yes || echo NO)"
echo "--- extra unapproved commit on top of identical rebase"
git -C "$LAB/wt-d" reset -q --hard main; git -C "$LAB/wt-d" cherry-pick -q "$rec"
echo extra > "$LAB/wt-d/sneaky.txt"; git -C "$LAB/wt-d" add sneaky.txt; git -C "$LAB/wt-d" commit -qm sneaky
land d; show; echo "record unchanged: $([ "$rec" = "$(head_of d)" ] && echo yes || echo NO)"
echo "--- conflict resolved differently: main changed the same file the lane touched"
mklane f README "lane F readme"; 
git -C "$P" worktree add -q -b fm/g "$LAB/wt-g" main; printf 'lane G readme\n' > "$LAB/wt-g/README"; git -C "$LAB/wt-g" commit -qam g
printf 'kind=ship\nmode=local-only\nbranch=fm/g\nproject=%s\nworktree=%s\nspawn_gen=lab-1\n' "$P" "$LAB/wt-g" > "$LAB/state/g.meta"
fm_dod_accept_ship_done ship local-only "$LAB/wt-g" "$P" "done [at=1790000000]: ready in branch fm/g" "$LAB/state" g "$LAB/state/g.meta" >/dev/null
land g >/dev/null; recf=$(head_of f)
git -C "$LAB/wt-f" rebase -q main 2>/dev/null || { printf 'lane F readme\n' > "$LAB/wt-f/README"; git -C "$LAB/wt-f" add README; GIT_EDITOR=true git -C "$LAB/wt-f" rebase --continue >/dev/null 2>&1; }
land f; show; echo "record unchanged: $([ "$recf" = "$(head_of f)" ] && echo yes || echo NO)"
echo "--- sanity: restoring D to an exact identical rebase lands"
git -C "$LAB/wt-d" reset -q --hard HEAD~1; land d; show

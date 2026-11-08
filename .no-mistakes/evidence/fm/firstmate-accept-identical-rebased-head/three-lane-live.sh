#!/usr/bin/env bash
# Live 3-lane scenario: real bin/fm-merge-local.sh + bin/fm-crew-state.sh in a disposable lab home.
set -u
WT_ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$WT_ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
SOCK="$TMUXD/tmux-$(id -u)/default"
cleanup() { [ -S "$SOCK" ] && tmux -S "$SOCK" kill-server 2>/dev/null; "$WT_ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
# External-boundary stub: no no-mistakes pipeline exists for these local-only lanes.
mkdir -p "$LAB/stubbin"
printf '#!/bin/sh\ncase "$1" in daemon) echo "  ● daemon running (pid 1)";; esac\nexit 0\n' > "$LAB/stubbin/no-mistakes"
chmod +x "$LAB/stubbin/no-mistakes"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
PROJ="$LAB/projects/demo"
git init -q -b main "$PROJ"
echo base > "$PROJ/README"; git -C "$PROJ" add README; git -C "$PROJ" commit -q -m base
run() { echo "\$ $*"; "$@" 2>&1; echo "[exit $?]"; }
E() { env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$TMUXD" PATH="$LAB/stubbin:$PATH" NM_HOME="$LAB/nm-unused" FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 "$@"; }
env -u TMUX TMUX_TMPDIR="$TMUXD" tmux new-session -d -s fm -n placeholder "sleep 600"
[ -S "$SOCK" ] || { echo "lab tmux socket missing at $SOCK"; exit 1; }
for lane in a b c; do
  WT="$LAB/wt-$lane"
  git -C "$PROJ" worktree add -q -b "fm/lane-$lane" "$WT" main
  echo "lane $lane work" > "$WT/$lane.txt"; git -C "$WT" add "$lane.txt"; git -C "$WT" commit -q -m "lane $lane"
  printf 'kind=ship\nmode=local-only\nbranch=fm/lane-%s\nproject=%s\nworktree=%s\nspawn_gen=lab-1\nwindow=fm:fm-lane-%s\nharness=claude\n' "$lane" "$PROJ" "$WT" "$lane" > "$LAB/state/lane-$lane.meta"
  env -u TMUX TMUX_TMPDIR="$TMUXD" tmux new-window -d -t fm: -n "fm-lane-$lane" "sleep 600"
  gen=$(E "$WT_ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "lane-$lane")
  E "$WT_ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "lane-$lane" idle --gen "$gen" --source claude-hook --event stop
  echo "done [at=$(date +%s)]: ready in branch fm/lane-$lane" > "$LAB/state/lane-$lane.status"
done
echo "== 1. all three lanes report done; readiness gate records each head"
for lane in a b c; do run E bash "$WT_ROOT/bin/fm-crew-state.sh" "lane-$lane"; grep local_done_head "$LAB/state/lane-$lane.meta"; done
echo "== 2. lane a lands first (moves main)"
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-a
echo "== 3. lane b, not rebased: refused as before with rebase hint"
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-b
echo "== 4. lane b rebases identically onto main; readiness still ready (not 'new task')"
git -C "$LAB/wt-b" rebase -q main
echo "lane b old head $(grep local_done_head "$LAB/state/lane-b.meta" | cut -d= -f2) new head $(git -C "$LAB/wt-b" rev-parse HEAD)"
run E bash "$WT_ROOT/bin/fm-crew-state.sh" lane-b
echo "== 5. lane b lands the identical rebase; record rebinds"
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-b
grep local_done_head "$LAB/state/lane-b.meta"; git -C "$PROJ" log --oneline main
echo "== 6. lane c rebased onto a's landing only, then b landed: main moved again"
C_REC=$(grep local_done_head "$LAB/state/lane-c.meta" | cut -d= -f2)
git -C "$LAB/wt-c" rebase -q "$(git -C "$PROJ" rev-parse main~1)"
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-c
echo "== 7. adversarial: lane c rebases onto current main but sneaks in edited content"
git -C "$LAB/wt-c" rebase -q main
echo "lane c work, edited" > "$LAB/wt-c/c.txt"; git -C "$LAB/wt-c" commit -q -a --amend -m "lane c"
run E bash "$WT_ROOT/bin/fm-crew-state.sh" lane-c
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-c
echo "record unchanged? $( [ "$(grep local_done_head "$LAB/state/lane-c.meta" | cut -d= -f2)" = "$C_REC" ] && echo yes || echo NO)"
echo "main still $(git -C "$PROJ" log --oneline -1 main)"
echo "== 8. adversarial: lane c adds an extra unapproved commit on an identical rebase"
git -C "$LAB/wt-c" reset -q --hard "$C_REC"; git -C "$LAB/wt-c" rebase -q main
echo extra > "$LAB/wt-c/extra.txt"; git -C "$LAB/wt-c" add extra.txt; git -C "$LAB/wt-c" commit -q -m extra
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-c
echo "== 9. lane c drops the extra commit: identical rebase lands"
git -C "$LAB/wt-c" reset -q --hard HEAD~1
run E bash "$WT_ROOT/bin/fm-crew-state.sh" lane-c
run E bash "$WT_ROOT/bin/fm-merge-local.sh" lane-c
grep local_done_head "$LAB/state/lane-c.meta"; git -C "$PROJ" log --oneline main; ls "$PROJ"; git -C "$PROJ" status --porcelain
echo "== lab removed on exit: $LAB"

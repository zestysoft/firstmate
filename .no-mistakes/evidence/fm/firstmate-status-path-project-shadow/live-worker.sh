#!/usr/bin/env bash
# Live check: render the REAL fm-spawn.sh launch brief (base vs target commit) in a
# disposable lab home for a project that tracks its own state/ and data/, then hand
# that exact launch brief to the REAL claude CLI running inside a linked worktree of
# that project, and observe where the worker writes its status log and report.
# Usage: live-claude-worker.sh <repo-root-to-use> <label>
set -u
SRC=$1 LABEL=$2
EV=~/.no-mistakes/evidence/01M6SW6PZPSHDPQEZC9W591SYE
OUT="$EV/live-${HARNESS:-claude}-${KIND:-scout}-$LABEL.txt"
LAB=$(cd "$(mktemp -d /tmp/fm-lab.XXXXXX)" && pwd -P); PR=$(cd "$(mktemp -d /tmp/fm-proj.XXXXXX)" && pwd -P)
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || true
[ -f "$LAB/.fm-lab-home" ] || { echo "lab home not marked" >&2; }
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects"
PROJ="$PR/proj"; WT="$PR/wt"; FAKEBIN="$LAB/fakebin"
mkdir -p "$PROJ" "$FAKEBIN"
git -C "$PROJ" init -q
printf '# demo project\nline two\nline three\n' > "$PROJ/README.md"
mkdir -p "$PROJ/state" "$PROJ/data"
printf 'project state\n' > "$PROJ/state/keep.txt"
printf 'project data\n' > "$PROJ/data/keep.txt"
git -C "$PROJ" add -A
git -c user.name=t -c user.email=t@example.com -C "$PROJ" commit -q -m 'project tracks state/ and data/'
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/tmux"; chmod +x "$FAKEBIN/tmux"
ID="shadow-${KIND:-scout}-$LABEL"
if [ "${KIND:-scout}" = ship ]; then SPAWNFLAGS="--mode no-mistakes --yolo off"; else SPAWNFLAGS=--scout; fi
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<EOF
You are a crewmate.

# Task
## Captain's intent
Count the lines in the project's README.md.

## Firstmate spec
Count the lines of README.md in your worktree. Append one progress line \`working: counting\` to \`state/$ID.status\`, then write your findings to \`data/$ID/report.md\`, then append \`done: report written\` to \`state/$ID.status\`. Do not commit anything. Then stop.

# Definition of done
The report exists and the status log ends with a done line.
EOF
[ "${KIND:-scout}" = ship ] && printf 'Delivery contract: mode=no-mistakes\n' >> "$LAB/data/$ID/brief.md"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
  FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
  "$SRC/bin/fm-spawn.sh" "$ID" "$PROJ" "${HARNESS:-claude}" $SPAWNFLAGS > "$LAB/spawn.log" 2>&1
BRIEF="$LAB/data/$ID/launch-brief.md"
{
  echo "=== $LABEL: lab home $LAB"
  echo "=== launch-brief.md rendered by real fm-spawn.sh: $( [ -f "$BRIEF" ] && echo yes || echo NO)"
  echo "--- worker role contract lines naming task records:"
  grep -n 'status log\|same-named\|steering inbox' "$BRIEF" | sed "s#$LAB#<LAB>#g"
} > "$OUT"
[ -f "$BRIEF" ] || { cat "$LAB/spawn.log" >> "$OUT"; rm -rf "$LAB"; exit 1; }
cp "$BRIEF" "$EV/launch-brief-${HARNESS:-claude}-${KIND:-scout}-$LABEL.md"; sed -i '' "s#$LAB#<LAB>#g" "$EV/launch-brief-${HARNESS:-claude}-${KIND:-scout}-$LABEL.md"
# The worker's worktree is a linked worktree of the project (the treehouse slot shape).
git -C "$PROJ" worktree add -q --detach "$WT"
if [ "${HARNESS:-claude}" = codex ]; then
  ( cd "$WT" && env -u NO_MISTAKES_GATE timeout 400 codex exec --dangerously-bypass-approvals-and-sandbox "$(cat "$BRIEF")" ) > "$LAB/claude.out" 2>&1
else
  ( cd "$WT" && env -u CLAUDECODE -u NO_MISTAKES_GATE timeout 400 claude -p --dangerously-skip-permissions \
    --max-turns 25 "$(cat "$BRIEF")" ) > "$LAB/claude.out" 2>&1
fi
echo "worker (${HARNESS:-claude}) exit=$?" >> "$OUT"
{
  echo "--- worker final output:"; tail -25 "$LAB/claude.out"
  echo "--- HOME records:"
  echo "home state/$ID.status: $( [ -f "$LAB/state/$ID.status" ] && echo PRESENT || echo absent)"
  [ -f "$LAB/state/$ID.status" ] && sed 's/^/    /' "$LAB/state/$ID.status"
  echo "home data/$ID/report.md: $( [ -f "$LAB/data/$ID/report.md" ] && echo PRESENT || echo absent)"
  echo "--- PROJECT worktree shadow records:"
  echo "worktree state/$ID.status: $( [ -f "$WT/state/$ID.status" ] && echo PRESENT || echo absent)"
  echo "worktree data/$ID/report.md: $( [ -f "$WT/data/$ID/report.md" ] && echo PRESENT || echo absent)"
  echo "worktree git status --porcelain:"; git -C "$WT" status --porcelain | sed 's/^/    /'
} | sed -e "s#$LAB#<LAB>#g" -e "s#$PR#<PROJ>#g" >> "$OUT"
git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null
rm -rf "$LAB" "$PR"
cat "$OUT"

#!/usr/bin/env bash
# usage: live-watch-env-arm.sh <marked-lab-home>   (run from the worktree)
LAB=$1
U=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CONFIG -u FM_PAUSE_RESURFACE_SECS TMUX_TMPDIR=$LAB/tmux FM_HOME=$LAB)
echo "\$ ls config (before bootstrap): $(ls $LAB/config)"
echo '$ fm-bootstrap.sh (no Relay token)'; "${U[@]}" bin/fm-bootstrap.sh 2>&1 | tail -5
echo "\$ ls config (after bootstrap): $(ls $LAB/config)"; cat $LAB/config/watch.env
echo '$ fm-watch-arm.sh'; "${U[@]}" timeout 20 bin/fm-watch-arm.sh > $LAB/arm.out 2>&1 &
sleep 8; echo "arm output so far:"; cat $LAB/arm.out
for p in $(pgrep -f "$PWD/bin/fm-watch.sh"); do
  ps eww -p $p -o command= | grep -q "FM_HOME=$LAB" && { echo "watcher pid $p env:"; ps eww -p $p -o command= | tr ' ' '\n' | grep -E '^FM_PAUSE_RESURFACE_SECS=|^FM_HOME='; }
done
wait; echo "--- arm output after exit:"; cat $LAB/arm.out
echo '$ fm-watch-arm.sh --stop'; "${U[@]}" bin/fm-watch-arm.sh --stop 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"

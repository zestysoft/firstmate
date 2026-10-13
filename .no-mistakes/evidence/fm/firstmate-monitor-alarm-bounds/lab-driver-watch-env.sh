#!/usr/bin/env bash
set -u
cd /Users/Ian/.no-mistakes/worktrees/260e8caa837a/01M4V380NG6PV7MNENZ2SJW5CM
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"; T() { tmux -L fm-lab "$@"; }
T new-session -d -s lab -n primary
export TMUX="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
RUN() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CONFIG -u FM_PAUSE_RESURFACE_SECS FM_HOME="$LAB" "$@"; }
watcher_env() { local p; p=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || pgrep -f "$PWD/bin/fm-watch.sh" | head -1); echo "watcher pid=$p FM_PAUSE_RESURFACE_SECS=$(ps eww -o command= -p "$p" | tr ' ' '\n' | grep '^FM_PAUSE_RESURFACE_SECS=' | cut -d= -f2)"; }
echo "== 1. captain persists tuning; a stale Relay artifact also exists; no Relay token in .env"
printf 'export FM_PAUSE_RESURFACE_SECS=777\n' > "$LAB/config/watch.env"
printf 'export FM_POLL=30\n' > "$LAB/config/x-mode.env"
ls "$LAB/config"
echo "== 2. real session-start bootstrap"
RUN bin/fm-bootstrap.sh 2>&1 | sed 's/^/  bootstrap> /' | head -20
echo "config after bootstrap: $(ls "$LAB/config" | tr '\n' ' ')"
cat "$LAB/config/watch.env"
echo "== 3. real watcher arm"
RUN bin/fm-watch-arm.sh > "$LAB/arm1.out" 2>&1 & ARM=$!
sleep 5; watcher_env
echo "== 4. Relay-opted-in home: x-mode.env sourced after watch.env wins"
printf 'export FM_PAUSE_RESURFACE_SECS=30\n' > "$LAB/config/x-mode.env"
timeout 20 env -u NO_MISTAKES_GATE FM_HOME="$LAB" bin/fm-watch-arm.sh --stop 2>&1 | sed 's/^/  stop> /' | head -3; wait $ARM 2>/dev/null
RUN bin/fm-watch-arm.sh > "$LAB/arm2.out" 2>&1 & ARM2=$!
for i in $(seq 1 100); do p=$(pgrep -f "$PWD/bin/fm-watch.sh" | head -1); [ -n "$p" ] && { echo "watcher pid=$p FM_PAUSE_RESURFACE_SECS=$(ps eww -o command= -p "$p" | tr ' ' '\n' | grep '^FM_PAUSE_RESURFACE_SECS=' | cut -d= -f2)"; break; }; sleep 0.1; done
timeout 20 env -u NO_MISTAKES_GATE FM_HOME="$LAB" bin/fm-watch-arm.sh --stop 2>&1 | sed 's/^/  stop> /' | head -5; kill $ARM $ARM2 2>/dev/null; sed 's/^/  arm1> /' "$LAB/arm1.out" | head -5; sed 's/^/  arm2> /' "$LAB/arm2.out" | head -5
sleep 1; pgrep -f "$PWD/bin/fm-watch.sh" >/dev/null && { echo "watcher still running; killing"; pkill -f "$PWD/bin/fm-watch.sh"; } || echo "watcher stopped"
T kill-server; rm -rf "$LAB"; echo "== lab torn down"

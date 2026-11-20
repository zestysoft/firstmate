#!/bin/bash
# usage: run.sh <side> <lab> <seconds> [tracer]
side=$1 lab=$2 secs=$3 trace=${4:-}
W=$(cat /tmp/fmtest_w_01M7)
cd "$W/$side"
envs=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE FM_HOME="$lab" FM_POLL=3 FM_SIGNAL_GRACE=${FM_SIGNAL_GRACE:-2} TMUX_TMPDIR="$lab/tmux")
if [ -n "$trace" ]; then envs+=(PATH="$W/shims:$PATH" FM_TRACE_REALPATH="$PATH" BASH_ENV="$W/bashenv.sh" FM_TRACE_LOG="$trace"); fi
"${envs[@]}" /bin/bash "$W/$side/bin/fm-watch.sh" > "$lab/watch.out" 2> "$lab/watch.err" &
pid=$!
for i in $(seq 1 "$secs"); do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid; echo "rc=still-running(killed)"; else wait $pid; echo "rc=$?"; fi

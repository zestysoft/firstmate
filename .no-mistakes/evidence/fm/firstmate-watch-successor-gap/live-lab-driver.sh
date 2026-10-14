#!/usr/bin/env bash
# Live lab: real pi primary + real extension + real fm-watch-arm/fm-watch in a lab home.
# usage: run.sh <fix|base> <none|dead-ready> <evidence-file>
set -u
variant=$1 fault=$2 evid=$3
WT=/Users/Ian/.no-mistakes/worktrees/260e8caa837a/01M4VWREHES97K2GJD3ZV6WPWH
case $variant in fix) rev=53cedb6 ;; base) rev=7df545b ;; esac
base=$(cd "$(mktemp -d "$TMPDIR/fmlab.XXXXXX")" && pwd -P)
root=$base/root home=$base/home
mkdir -p "$root"
git -C "$WT" archive "$rev" | tar -x -C "$root"
"$root/bin/fm-lab-home.sh" create "$home" >/dev/null
sock=$("$root/bin/fm-lab-home.sh" tmux-dir "$home")
T() { TMUX_TMPDIR=$sock tmux -L fmlab "$@"; }
mv "$root/bin/fm-watch-arm.sh" "$root/bin/fm-watch-arm-real.sh"
cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# lab fault injector: delegates to the real arm, except the 2nd cycle under dead-ready
d=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in --handling-delivered|--stop|--status) exec "$d/fm-watch-arm-real.sh" "$@" ;; esac
printf '%s arm=%s\n' "$(date +%H:%M:%S.%N 2>/dev/null || date +%T)" "$$" >> "$FM_LAB_ARMLOG"
n=$(grep -c ' arm=' "$FM_LAB_ARMLOG")
if [ "$FM_LAB_FAULT" = dead-ready ] && [ "$n" -eq 2 ]; then
  ( p=$$; while kill -0 "$p" 2>/dev/null; do sleep 0.01; done
    printf 'watcher: started pid=%s (beacon fresh) recovery-generation=lab-dead-ready\n' "$p"
    while [ ! -e "$FM_LAB_RELEASE" ]; do sleep 0.1; done ) &
  exit 0
fi
exec "$d/fm-watch-arm-real.sh" "$@"
SH
chmod +x "$root/bin/fm-watch-arm.sh"
armlog=$base/arms.log release=$base/release
: > "$armlog"
ext=$root/.pi/extensions/fm-primary-pi-watch.ts
prompt='You are a lab test harness. Step 1: call the fm_watch_arm_pi tool exactly once now, then reply DONE. Later, whenever a watcher wake notification arrives, do NOT call any tool and do NOT run any command; reply only with the single word ACK.'
T new-session -d -s lab -x 200 -y 50 -c "$root" \
  "env FM_HOME=$home FM_LAB_ARMLOG=$armlog FM_LAB_FAULT=$fault FM_LAB_RELEASE=$release pi --no-session -na -ne -e $ext -nc --no-mcp -ns -np --no-themes --tui-mode regular --thinking off --model vultr/deepseek-v4.1-flash \"$prompt\"; sleep 600"
pipid=""
for _ in $(seq 100); do pipid=$(pgrep -f -- "-e $ext" | head -1); [ -n "$pipid" ] && break; sleep 0.1; done
echo "$pipid" > "$home/state/.lock"
procs() { ps -axo pid=,ppid=,command= | grep -F "$root/bin/fm-watch" | grep -v grep | sed 's/^/    /'; }
{
echo "=== live lab: variant=$variant rev=$rev fault=$fault"
echo "lab root=$root"; echo "lab home=$home (marker: $(ls "$home/.fm-lab-home"))"; echo "pi pid=$pipid lock=$(cat "$home/state/.lock")"
echo "pi: $(pi --version 2>&1 | tail -1) model=vultr/deepseek-v4.1-flash (CLI flag only) (watcher thresholds at product defaults)"
} > "$evid"
for _ in $(seq 300); do procs | grep -q 'fm-watch.sh$' && break; sleep 0.2; done
sleep 3
echo "--- $(date +%T) watcher up before wake:" >> "$evid"; procs >> "$evid"
printf 'done: lab crew finished its task\n' >> "$home/state/crew.status"
echo "--- $(date +%T) wrote real worker event: state/crew.status 'done: lab crew finished its task'" >> "$evid"
deadline=$((SECONDS+240)); seen=0; cnt=0
while [ $SECONDS -lt $deadline ]; do
  pane=$(T capture-pane -p -S -500 -t lab 2>/dev/null)
  c=$(printf '%s' "$pane" | grep -c 'FIRSTMATE WATCHER WAKE')
  if [ "$c" -gt "$cnt" ]; then
    cnt=$c
    { echo "--- $(date +%T) WAKE visible in Pi pane (#$cnt). arm invocations so far:"; sed 's/^/    /' "$armlog"
      echo "  live lab watcher/arm processes at that moment:"; p=$(procs); echo "${p:-    NONE - nothing is watching}"; } >> "$evid"
    [ "$seen" = 1 ] || seen_at=$SECONDS; seen=1
  fi
  [ "$seen" = 1 ] && [ $SECONDS -gt $((seen_at+25)) ] && break
  sleep 0.2
done
sleep 5
{ echo "--- $(date +%T) after settle (~30s after first wake):"; p=$(procs); echo "${p:-    NONE - nothing is watching}"
  echo "--- extension log:"; sed 's/^/    /' "$home/state/.watch-extension.log" 2>/dev/null
  echo "--- arm log:"; sed 's/^/    /' "$armlog"
  echo "--- pi pane tail:"; T capture-pane -p -S -200 -t lab | grep -v '^\s*$' | tail -40 | sed 's/^/    /'; } >> "$evid"
# teardown: only our processes
touch "$release"
T kill-server 2>/dev/null
sleep 2
for pid in $(ps -axo pid=,command= | grep -F "$root" | grep -v grep | awk '{print $1}'); do kill "$pid" 2>/dev/null; done
sleep 1
left=$(ps -axo pid=,command= | grep -F "$base" | grep -v grep)
"$root/bin/fm-lab-home.sh" teardown "$home"
echo "--- teardown: leftover lab processes: ${left:-none}" >> "$evid"
rm -rf "$base"

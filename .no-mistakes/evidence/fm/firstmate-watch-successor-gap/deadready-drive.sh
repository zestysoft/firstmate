#!/usr/bin/env bash
set -u
V=$1; D=$2; ROOT=$3; EV=$4
LAB="$D/$V"; PROJECT="$LAB/project"; H="$LAB/home"
mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
for f in fm-branch-dispatch fm-native-contract fm-async-exec fm-operational-input fm-calm-visibility; do
  cp "$ROOT/.pi/extensions/lib/$f.ts" "$PROJECT/.pi/extensions/lib/$f.ts"; done
cp "$D/ext-$V.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$D/arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo "lab home create failed"; exit 1; }
cp "$D/holder.sh" "$H/holder.sh"
TMD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$H")
TM() { TMUX_TMPDIR="$TMD" tmux -L "fm-lab-dr-$V" "$@"; }
cap() { TM capture-pane -p -t primary -S -400 2>/dev/null; }
cleanup() {
  touch "$H/stop" 2>/dev/null
  TM kill-server 2>/dev/null; sleep 0.5
  for p in $(pgrep -f "$LAB" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
  "$ROOT/bin/fm-lab-home.sh" teardown "$H" >/dev/null 2>&1; sleep 0.3; rm -rf "$LAB"
}
trap cleanup EXIT
TM new-session -d -x 200 -y 60 -s primary -c "$PROJECT" \
  "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$H' FM_ROOT_OVERRIDE='$PROJECT' FM_WATCH_REARM_RETRY_BASE_MS=50 FM_WATCH_REARM_RETRY_MAX_MS=200 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-primary-pi-watch.ts --model openai/gpt-5.6-sol --thinking low; echo PI_EXIT=\$?; sleep 120'"
for i in $(seq 120); do [ -f "$H/state/.pi-watch-extension-loaded" ] && cap | grep -Fq "(openai)" && break; sleep 0.5; done
cap | grep -Fq "(openai)" || { echo "pi not ready"; cap; exit 1; }
sleep 1
TM send-keys -t primary -l "Call the fm_watch_arm_pi tool once now (never use bash). Later a watcher notification will arrive; when it does, reply exactly GOT_WAKE and do nothing else."
TM send-keys -t primary Enter
for i in $(seq 600); do cap | grep -Eq "Pi extension arm child|already owns an arm" && break; sleep 0.5; done
cap | grep -Eq "Pi extension arm child|already owns an arm" || { echo "arm tool never ran"; cap; exit 1; }
sleep 4
echo "trigger t=$(python3 -c 'import time;print(int(time.time()*1000))')" >> "$H/arm.log"
touch "$H/trigger"
seen=0
for i in $(seq 2400); do
  if cap | grep -Fq "DEADREADY_WAKE"; then
    seen=1
    now=$(python3 -c 'import time;print(int(time.time()*1000))')
    alive=""
    for p in $(sed -n 's/^arm=\([0-9]*\).*/\1/p' "$H/arm.log"); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    echo "WAKE_VISIBLE_IN_PI t=$now live_arm_pids=[${alive# }]" >> "$H/arm.log"
    break
  fi
  sleep 0.05
done
[ "$seen" = 1 ] || echo "WAKE_NEVER_VISIBLE" >> "$H/arm.log"
for i in $(seq 300); do cap | grep -Fxq " GOT_WAKE" && break; sleep 0.5; done
sleep 2
alive=""
for p in $(sed -n 's/^arm=\([0-9]*\).*/\1/p' "$H/arm.log"); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
echo "AFTER_SETTLE live_arm_pids=[${alive# }]" >> "$H/arm.log"
{ echo "=== arm.log ($V)"; cat "$H/arm.log"; echo "=== .watch-extension.log ($V)"; cat "$H/state/.watch-extension.log" 2>/dev/null; } > "$EV/deadready-$V-receipts.txt"
cap > "$EV/deadready-$V-pi-pane.txt"
cat "$EV/deadready-$V-receipts.txt"

#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
L="${FM_HOME:?}/arm.log"
printf 'arm=%s t=%s\n' "$$" "$(python3 -c 'import time;print(int(time.time()*1000))')" >> "$L"
count=$(grep -c '^arm=' "$L")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  while [ ! -e "$FM_HOME/trigger" ]; do sleep 0.1; done
  printf 'signal: DEADREADY_WAKE from fixture watcher\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  ("$FM_HOME/holder.sh" "$$" >&1 2>/dev/null &)
  exit 0
fi
printf 'live=%s\n' "$$" >> "$L"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-successor\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_HOME/stop" ]; do sleep 0.1; done

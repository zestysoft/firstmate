#!/usr/bin/env bash
parent=$1
while kill -0 "$parent" 2>/dev/null; do sleep 0.01; done
printf 'holder: parent %s dead, printing ready\n' "$parent" >> "$FM_HOME/arm.log"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=dead-ready\n' "$parent"
while [ ! -e "$FM_HOME/stop" ]; do sleep 0.1; done

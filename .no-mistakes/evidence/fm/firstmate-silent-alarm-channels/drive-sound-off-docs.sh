#!/usr/bin/env bash
# Drives the documented sound:off append commands (extracted verbatim from the
# docs at the target commit) against disposable homes, then runs the real
# fm-usage-warner.sh check and the real daemon wedge_alarm_notify to show which
# config each consumer reads. osascript/quota-axi/uname are argv-recording fakes
# (external boundary only); no real banner is posted.
set -u
WT=${1:?worktree}; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sound-docs.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
extract() { grep -o "printf '\\\\nsound:off\\\\n' >> \"[^\`]*" "$1" | head -1; }
UW_CMD=$(extract "$WT/docs/configuration.md"); WA_CMD=$(extract "$WT/docs/wedge-alarm.md")
OLD_UW='printf '"'"'\nsound:off\n'"'"' >> "${FM_HOME:-.}/config/usage-warner"'
echo "doc command (configuration.md): $UW_CMD"
echo "doc command (wedge-alarm.md):   $WA_CMD"
FB="$LAB/fakebin"; mkdir -p "$FB"
cat > "$FB/quota-axi" <<'Q'
#!/usr/bin/env bash
cat <<'JSON'
{"generatedAt":"t","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"team","account":{"accountId":"x","email":"a@b.c","organization":"o","identityStatus":"verified"},"windows":[{"id":"five_hour","percentUsed":85}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"t","sourcesTried":[]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset"}}]}}]}
JSON
Q
printf '#!/usr/bin/env bash\nfor a in "$@"; do printf "<%%s>\\n" "$a"; done >> "$OSA_LOG"\n' > "$FB/osascript"
printf '#!/bin/sh\necho Darwin\n' > "$FB/uname"; chmod +x "$FB"/*

warner_case() {  # <label> <append-cmd> <use-override:0|1>
  local label=$1 cmd=$2 ov=$3 home="$LAB/$1" cfg; mkdir -p "$home/state" "$home/config" "$home/custom-config"
  if [ "$ov" = 1 ]; then cfg="$home/custom-config"; else cfg="$home/config"; fi
  printf 'five_hour:80\n' > "$cfg/usage-warner"
  export OSA_LOG="$home/osa.log"; : > "$OSA_LOG"
  if [ "$ov" = 1 ]; then (export FM_HOME="$home" FM_CONFIG_OVERRIDE="$cfg"; eval "$cmd"; PATH="$FB:$PATH" "$WT/bin/fm-usage-warner.sh" check </dev/null)
  else (export FM_HOME="$home"; unset FM_CONFIG_OVERRIDE; eval "$cmd"; PATH="$FB:$PATH" "$WT/bin/fm-usage-warner.sh" check </dev/null); fi
  echo "--- usage-warner [$label] override=$ov"
  for f in "$home/config/usage-warner" "$home/custom-config/usage-warner"; do [ -f "$f" ] && { echo "  ${f#$home/}:"; sed 's/^/    | /' "$f"; }; done
  echo "  osascript argv:"; sed 's/^/    /' "$OSA_LOG"
  if grep -q 'sound name ""' "$OSA_LOG"; then echo "  RESULT: silent (sound name \"\")"; else echo "  RESULT: AUDIBLE (default sound)"; fi
}
wedge_case() {  # <label> <append-cmd> <use-override>
  local label=$1 cmd=$2 ov=$3 home="$LAB/$1" cfg; mkdir -p "$home/state" "$home/config" "$home/custom-config"
  if [ "$ov" = 1 ]; then cfg="$home/custom-config"; else cfg="$home/config"; fi
  export OSA_LOG="$home/osa.log"; : > "$OSA_LOG"
  (export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"; if [ "$ov" = 1 ]; then export FM_CONFIG_OVERRIDE="$cfg"; else unset FM_CONFIG_OVERRIDE; fi
   eval "$cmd"
   PATH="$FB:$PATH" bash -c '. "$1"; FM_WEDGE_ALARM_EXEC= FM_WEDGE_ALARM_CHANNEL= wedge_alarm_notify "away-mode WEDGED 900s" /s/.marker' _ "$WT/bin/fm-supervise-daemon.sh" >/dev/null 2>&1)
  echo "--- wedge-alarm [$label] override=$ov"
  for f in "$home/config/wedge-alarm" "$home/custom-config/wedge-alarm"; do [ -f "$f" ] && { echo "  ${f#$home/}:"; sed 's/^/    | /' "$f"; }; done
  echo "  osascript argv:"; sed 's/^/    /' "$OSA_LOG"
  if grep -qx '<>' "$OSA_LOG"; then echo "  RESULT: silent (empty sound name)"; elif grep -qx '<Basso>' "$OSA_LOG"; then echo "  RESULT: AUDIBLE (Basso)"; else echo "  RESULT: no banner"; fi
}
warner_case uw-doc-override "$UW_CMD" 1
warner_case uw-doc-nooverride "$UW_CMD" 0
warner_case uw-OLD-override "$OLD_UW" 1
wedge_case wa-doc-override "$WA_CMD" 1
wedge_case wa-doc-nooverride "$WA_CMD" 0
wedge_case wa-OLD-override 'printf '"'"'\nsound:off\n'"'"' >> "${FM_HOME:-.}/config/wedge-alarm"' 1
echo "--- unset FM_HOME and FM_CONFIG_OVERRIDE: path the doc commands resolve to"
(cd "$LAB" && unset FM_HOME FM_CONFIG_OVERRIDE && mkdir -p config && eval "$UW_CMD" && eval "$WA_CMD" && ls config)

#!/usr/bin/env bash
# Live drive of the silent-banner change on a real Mac.
# Real bin/fm-usage-warner.sh and real bin/fm-supervise-daemon.sh wedge_alarm_notify,
# posting through the REAL /usr/bin/osascript (a PATH shim only records argv, then execs it).
# Oracle: usernoted's own log line "hasSound: true|false" for each posted banner.
# Synthetic input: a fake quota-axi (external dependency) reporting five_hour at 85%.
set -u
WT=$1
cd "$WT" || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
OVR=$(mktemp -d "${TMPDIR:-/tmp}/fm-ovr.XXXXXX")   # custom config dir (FM_CONFIG_OVERRIDE)
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
trap 'rm -rf "$LAB" "$OVR" "$SHIM"' EXIT
ARGV_LOG="$SHIM/argv.log"
cat > "$SHIM/osascript" <<EOF
#!/usr/bin/env bash
{ printf -- '--- osascript call\n'; for a in "\$@"; do printf '<%s>\n' "\$a"; done; } >> "$ARGV_LOG"
exec /usr/bin/osascript "\$@"
EOF
cat > "$SHIM/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"generatedAt":"t","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"team","account":{"accountId":"x","email":"a@b.c","organization":"o","identityStatus":"verified"},"windows":[{"id":"five_hour","percentUsed":85}],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"t","sourcesTried":[]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset"}}]}}]}
JSON
EOF
chmod +x "$SHIM/osascript" "$SHIM/quota-axi"

# The two documented append commands, extracted verbatim from the docs.
doc_cmd() { grep -o "printf '\\\\nsound:off\\\\n' >> \"[^\"]*/$1\"" "$2" | head -1; }
UW_CMD=$(doc_cmd usage-warner docs/configuration.md)
WA_CMD=$(doc_cmd wedge-alarm docs/wedge-alarm.md)
echo "doc command (configuration.md): $UW_CMD"
echo "doc command (wedge-alarm.md):   $WA_CMD"

hassound() {  # <start-time>: usernoted's hasSound verdicts since start
  sleep 3
  /usr/bin/log show --start "$1" --style compact --predicate 'process == "usernoted"' 2>/dev/null \
    | grep -o 'hasSound: [a-z]*' | sort -u | tr '\n' ' '
}
banner_args() { cat "$ARGV_LOG"; }

run_warner() {
  rm -f "$LAB/state/.usage-warner"; : > "$ARGV_LOG"
  local t; t=$(date '+%Y-%m-%d %H:%M:%S')
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE PATH="$SHIM:$PATH" FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$OVR" \
    bin/fm-usage-warner.sh check </dev/null; echo "warner check rc=$?"
  echo "osascript argv:"; banner_args
  echo "usernoted: $(hassound "$t")"
}
run_wedge() {
  : > "$ARGV_LOG"
  local t; t=$(date '+%Y-%m-%d %H:%M:%S')
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_WEDGE_ALARM_CHANNEL PATH="$SHIM:$PATH" FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$OVR" \
    bash -c '. bin/fm-supervise-daemon.sh; log() { printf "daemon log: %s\n" "$*"; }; FM_WEDGE_ALARM_EXEC= wedge_alarm_notify "gate live probe: wedge" "$FM_HOME/state/.subsuper-inject-wedged"; echo "wedge_alarm_notify rc=$?"'
  echo "osascript argv:"; banner_args
  echo "usernoted: $(hassound "$t")"
}

echo; echo "=== S1 usage warner, default config (threshold only) in custom config dir"
printf 'five_hour:80\n' > "$OVR/usage-warner"
run_warner

echo; echo "=== S2 usage warner, follow configuration.md command with FM_CONFIG_OVERRIDE set"
( export FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$OVR"; eval "$UW_CMD" )
echo "custom dir usage-warner now:"; sed 's/^/  | /' "$OVR/usage-warner"
echo "lab \$FM_HOME/config/usage-warner exists? $([ -e "$LAB/config/usage-warner" ] && echo yes || echo no)"
run_warner

echo; echo "=== S3 wedge alarm, no config/wedge-alarm (auto default)"
run_wedge

echo; echo "=== S4 adversarial: pre-fix command \${FM_HOME:-.}/config/wedge-alarm with FM_CONFIG_OVERRIDE set"
( export FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$OVR"; printf '\nsound:off\n' >> "${FM_HOME:-.}/config/wedge-alarm" )
echo "custom dir wedge-alarm exists? $([ -e "$OVR/wedge-alarm" ] && echo yes || echo no)  (alarm reads the custom dir)"
run_wedge
rm -f "$LAB/config/wedge-alarm"

echo; echo "=== S5 wedge alarm, follow wedge-alarm.md command with FM_CONFIG_OVERRIDE set (file holds only sound:off)"
( export FM_HOME="$LAB" FM_CONFIG_OVERRIDE="$OVR"; eval "$WA_CMD" )
echo "custom dir wedge-alarm now:"; sed 's/^/  | /' "$OVR/wedge-alarm"
run_wedge

echo; echo "=== S6 wedge alarm, delete the sound:off line (restore sound)"
grep -v '^sound:off$' "$OVR/wedge-alarm" > "$OVR/wa.tmp"; mv "$OVR/wa.tmp" "$OVR/wedge-alarm"
run_wedge

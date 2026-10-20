#!/usr/bin/env bash
set -eu
ROOT=$PWD
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "$PWD/.fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
for harness in codex claude; do
  if [ "$harness" = codex ]; then setting=codex-approval-mode; value=approve-for-me; else setting=claude-permission-mode; value=auto; fi
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$LAB/state/probe.meta"
  printf '%s\n' "$$" > "$LAB/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$LAB/state/.lease-probe"
  echo "=== $harness: another actor's live lease ==="
  rc=0
  FM_SUPERVISION_ACTOR=main bash bin/fm-approval-failover.sh apply probe || rc=$?
  [ "$rc" = 6 ] && [ ! -e "$LAB/config/$setting" ]
  rm "$LAB/state/.lock" "$LAB/state/.lease-probe"
  echo "=== $harness: missing endpoint reports saved fallback and incomplete recovery ==="
  rc=0
  bash bin/fm-approval-failover.sh apply probe || rc=$?
  [ "$rc" != 0 ] && [ "$(cat "$LAB/config/$setting")" = "$value" ]
  perl -e 'printf "saved=%s links=%s\n", $ARGV[0], (stat($ARGV[0]))[3]; die "hardlinked" unless (stat($ARGV[0]))[3] == 1' "$LAB/config/$setting"
  echo "=== $harness: explicit setting protected ==="
  rc=0
  bash bin/fm-approval-failover.sh apply probe || rc=$?
  [ "$rc" != 0 ] && [ "$(cat "$LAB/config/$setting")" = "$value" ]
done
mkdir -p "$LAB/primary/config" "$LAB/local/config"
. bin/fm-config-inherit-lib.sh
for setting in codex-approval-mode claude-permission-mode; do
  if [ "$setting" = codex-approval-mode ]; then value=approve-for-me; else value=auto; fi
  printf '%s\n' "$value" > "$LAB/local/config/$setting"
  propagate_inheritable_config "$LAB/primary/config" "$LAB/local/config"
  printf 'local absent primary: %s=%s\n' "$setting" "$(cat "$LAB/local/config/$setting")"
  [ "$(cat "$LAB/local/config/$setting")" = "$value" ]
  hash=$(printf '' | shasum -a 256 | awk '{print $1}')
  bash bin/fm-remote-inherit.sh absent "config/$setting" 0 "$hash" 1
  [ "$(cat "$LAB/config/$setting")" = "$value" ]
  printf 'bypass\n' > "$LAB/primary/config/$setting"
  propagate_inheritable_config "$LAB/primary/config" "$LAB/local/config"
  printf 'explicit primary: %s=%s\n' "$setting" "$(cat "$LAB/local/config/$setting")"
  [ "$(cat "$LAB/local/config/$setting")" = bypass ]
  hash=$(printf 'bypass\n' | shasum -a 256 | awk '{print $1}')
  printf 'bypass\n' | bash bin/fm-remote-inherit.sh put "config/$setting" 7 "$hash" 2
  [ "$(cat "$LAB/config/$setting")" = bypass ]
done
echo '=== gate refusal before lease cleanup in an unmarked disposable home ==='
rm "$LAB/.fm-lab-home"
printf 'branch\t0\t1\n' > "$LAB/state/.lease-probe"
cp "$LAB/state/.lease-probe" "$LAB/lease-before"
rc=0
NO_MISTAKES_GATE=1 bash bin/fm-approval-failover.sh apply probe || rc=$?
[ "$rc" = 3 ]
cmp "$LAB/lease-before" "$LAB/state/.lease-probe"
echo 'All public-interface boundary assertions satisfied'

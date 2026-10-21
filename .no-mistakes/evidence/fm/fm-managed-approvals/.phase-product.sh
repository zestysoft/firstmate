#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/ian.brown/.no-mistakes/evidence/01M5FZWDRH0GVV50DFXZZ5X38S
LAB=$(mktemp -d "$PWD/.phase-product.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SUPERVISION_ACTOR
for harness in codex claude; do
  if [ "$harness" = codex ]; then setting=codex-approval-mode; fallback=approve-for-me; else setting=claude-permission-mode; fallback=auto; fi
  echo "=== $harness real command boundaries ==="
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$LAB/state/task.meta"
  printf 'bypass\n' > "$LAB/config/$setting"
  rc=0
  bin/fm-approval-failover.sh apply task || rc=$?
  [ "$rc" != 0 ] && [ "$(cat "$LAB/config/$setting")" = bypass ]
  echo "existing explicit bypass preserved; exit=$rc"
  rm "$LAB/config/$setting"
  printf 'harness=%s\napproval_mode=%s\n' "$harness" "$fallback" > "$LAB/state/task.meta"
  rc=0
  bin/fm-approval-failover.sh apply task || rc=$?
  [ "$rc" != 0 ] && [ ! -e "$LAB/config/$setting" ]
  echo "non-bypass record refused without saving; exit=$rc"
  printf 'harness=%s\napproval_mode=bypass\nremote_host=elsewhere\n' "$harness" > "$LAB/state/task.meta"
  rc=0
  bin/fm-approval-failover.sh apply task || rc=$?
  [ "$rc" != 0 ] && [ ! -e "$LAB/config/$setting" ]
  echo "remote supervisor record refused without saving; exit=$rc"
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$LAB/state/task.meta"
  rc=0
  bin/fm-approval-failover.sh apply task > "$LAB/recovery.out" 2>&1 || rc=$?
  cat "$LAB/recovery.out"
  [ "$rc" != 0 ] && [ "$(cat "$LAB/config/$setting")" = "$fallback" ]
  links=$(perl -e 'print((stat($ARGV[0]))[3])' "$LAB/config/$setting")
  [ "$links" = 1 ]
  echo "missing endpoint reports incomplete recovery; saved $setting=$(cat "$LAB/config/$setting"); links=$links; exit=$rc"
  rm "$LAB/config/$setting"
  printf 'invalid\n' > "$LAB/config/$setting"
  rc=0
  bin/fm-spawn.sh live-invalid "$ROOT" --scout --harness "$harness" > "$LAB/invalid.out" 2>&1 || rc=$?
  cat "$LAB/invalid.out"
  [ "$rc" != 0 ] && [ ! -e "$LAB/state/live-invalid.meta" ]
  echo "invalid $setting refused; no task record; exit=$rc"
  rm "$LAB/config/$setting"
done
. bin/fm-config-inherit-lib.sh
mkdir -p "$LAB/primary/config" "$LAB/child/config" "$LAB/remote/config"
empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
bypass_hash=$(printf 'bypass\n' | shasum -a 256 | awk '{print $1}')
for setting in codex-approval-mode claude-permission-mode; do
  if [ "$setting" = codex-approval-mode ]; then fallback=approve-for-me; else fallback=auto; fi
  printf '%s\n' "$fallback" > "$LAB/child/config/$setting"
  printf '%s\n' "$fallback" > "$LAB/remote/config/$setting"
  printf 'bypass\n' > "$LAB/primary/config/$setting"
  propagate_inheritable_config "$LAB/primary/config" "$LAB/child/config"
  printf 'bypass\n' | FM_HOME="$LAB/remote" bin/fm-remote-inherit.sh put "config/$setting" 7 "$bypass_hash" 1
  [ "$(cat "$LAB/child/config/$setting")" = bypass ] && [ "$(cat "$LAB/remote/config/$setting")" = bypass ]
  echo "$setting: explicit primary bypass replaces local and remote fallback"
  rm "$LAB/primary/config/$setting"
  propagate_inheritable_config "$LAB/primary/config" "$LAB/child/config"
  FM_HOME="$LAB/remote" bin/fm-remote-inherit.sh absent "config/$setting" 0 "$empty_hash" 2
  [ ! -e "$LAB/child/config/$setting" ] && [ ! -e "$LAB/remote/config/$setting" ]
  echo "$setting: primary absence clears both local and remote copies"
done
mkdir -p "$LAB/unmarked/config" "$LAB/unmarked/state"
printf 'harness=codex\napproval_mode=bypass\n' > "$LAB/unmarked/state/task.meta"
rc=0
FM_HOME="$LAB/unmarked" NO_MISTAKES_GATE=1 bin/fm-approval-failover.sh apply task || rc=$?
[ "$rc" = 3 ] && [ ! -e "$LAB/unmarked/config/codex-approval-mode" ] && [ ! -e "$LAB/unmarked/state/.fm-lease-command.lock" ]
echo "unmarked home gate refusal exit=$rc; no configuration or lease-lock mutation"

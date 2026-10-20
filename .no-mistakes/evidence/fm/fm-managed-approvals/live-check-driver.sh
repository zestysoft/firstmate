#!/usr/bin/env bash
set -eu
root=$PWD
for harness in codex claude; do
  lab=$(bin/fm-lab-home.sh create "$root/.l/$harness")
  case $harness in codex) setting=codex-approval-mode; fallback=approve-for-me;; claude) setting=claude-permission-mode; fallback=auto;; esac
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$lab/state/task.meta"
  run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u FM_SUPERVISION_ACTOR FM_HOME="$lab" "$root/bin/fm-approval-failover.sh" apply task; }
  printf '\n=== %s real apply, unavailable worker ===\n' "$harness"
  rc=0; run || rc=$?
  test "$rc" = 1
  printf 'persisted setting: '; cat "$lab/config/$setting"
  test "$(cat "$lab/config/$setting")" = "$fallback"
  perl -e 'printf "published file links: %s\n", (stat($ARGV[0]))[3]; die if (stat($ARGV[0]))[3] != 1' "$lab/config/$setting"
  printf '=== repeat preserves explicit setting ===\n'
  printf 'bypass\n' > "$lab/config/$setting"
  rc=0; run || rc=$?; test "$rc" = 1
  test "$(cat "$lab/config/$setting")" = bypass
  printf 'preserved setting: '; cat "$lab/config/$setting"
  rm "$lab/config/$setting"
  printf '%s\n' "$$" > "$lab/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$lab/state/.lease-task"
  printf '=== other actor refuses before publication ===\n'
  rc=0; run || rc=$?; test "$rc" = 6; test ! -e "$lab/config/$setting"
  rm "$lab/state/.lock" "$lab/state/.lease-task"
  printf '=== primary authoritative local and remote inheritance ===\n'
  mkdir -p "$lab/primary/config" "$lab/local/config" "$lab/remote/config"
  . bin/fm-config-inherit-lib.sh
  printf '%s\n' "$fallback" > "$lab/local/config/$setting"
  printf '%s\n' "$fallback" > "$lab/remote/config/$setting"
  propagate_inheritable_config "$lab/primary/config" "$lab/local/config"
  empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
  FM_HOME="$lab/remote" bin/fm-remote-inherit.sh absent "config/$setting" 0 "$empty_hash" 1
  test ! -e "$lab/local/config/$setting"; test ! -e "$lab/remote/config/$setting"
  printf 'primary absent: local and remote mode removed\n'
  printf 'bypass\n' > "$lab/primary/config/$setting"
  propagate_inheritable_config "$lab/primary/config" "$lab/local/config"
  hash=$(printf 'bypass\n' | shasum -a 256 | awk '{print $1}')
  printf 'bypass\n' | FM_HOME="$lab/remote" bin/fm-remote-inherit.sh put "config/$setting" 7 "$hash" 2
  test "$(cat "$lab/local/config/$setting")" = bypass; test "$(cat "$lab/remote/config/$setting")" = bypass
  printf 'primary explicit: local='; cat "$lab/local/config/$setting"; printf 'remote='; cat "$lab/remote/config/$setting"
done
printf '\n=== gate refuses nonlab home before any mutation ===\n'
mkdir -p "$root/.l/nonlab/config"
rc=0
env -u FM_GATE_REFUSE_BYPASS FM_HOME="$root/.l/nonlab" bin/fm-approval-failover.sh apply task || rc=$?
test "$rc" = 3
test ! -e "$root/.l/nonlab/state"
printf 'nonlab home unchanged\n'

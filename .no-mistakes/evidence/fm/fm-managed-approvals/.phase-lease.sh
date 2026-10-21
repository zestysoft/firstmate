#!/usr/bin/env bash
set -eu
LAB=$(mktemp -d "$PWD/.phase-lease.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SUPERVISION_ACTOR
for harness in codex claude; do
  if [ "$harness" = codex ]; then setting=codex-approval-mode; else setting=claude-permission-mode; fi
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$LAB/state/task.meta"
  printf '%s\n' "$$" > "$LAB/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$LAB/state/.lease-task"
  printf 'blocked: preserve this event\n' > "$LAB/state/task.status"
  cp "$LAB/state/task.status" "$LAB/status.before"
  rc=0
  FM_SUPERVISION_ACTOR=main bin/fm-approval-failover.sh apply task || rc=$?
  [ "$rc" = 6 ] && [ ! -e "$LAB/config/$setting" ]
  cmp "$LAB/status.before" "$LAB/state/task.status"
  echo "$harness: another actor's live lease refuses apply (exit=$rc), preserves configuration and task status"
  rm "$LAB/state/.lock" "$LAB/state/.lease-task"
  mkdir -p "$LAB/unmarked-$harness/config" "$LAB/unmarked-$harness/state"
  cp "$LAB/state/task.meta" "$LAB/unmarked-$harness/state/task.meta"
  rc=0
  FM_HOME="$LAB/unmarked-$harness" NO_MISTAKES_GATE=1 bin/fm-approval-failover.sh apply task || rc=$?
  [ "$rc" = 3 ] && [ ! -e "$LAB/unmarked-$harness/config/$setting" ] && [ ! -e "$LAB/unmarked-$harness/state/.fm-lease-command.lock" ]
  echo "$harness: gate caller refused (exit=$rc) before configuration or lease-lock mutation"
done

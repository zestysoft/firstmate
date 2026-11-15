#!/usr/bin/env bash
# Usage: drive-shape-spy.sh <tree-root> <test-file>
# Sources <tree-root>/tests/lib.sh (so ROOT=<tree-root>, real bin/fm-spawn.sh),
# loads helpers + test_launch_contract_names_home_task_records from <test-file>,
# and wraps run_spawn to print, per spawn, which files the project tracks under state/ data/.
set -u
TREE=$1; TF=$2
. "$TREE/tests/lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-shape-spy)
eval "$(awk '/^make_home\(\)/,/^}/' "$TF")"
eval "$(awk '/^write_brief\(\)/,/^}/' "$TF")"
eval "$(awk '/^run_spawn\(\)/,/^}/' "$TF" | sed 's/^run_spawn()/real_run_spawn()/')"
eval "$(awk '/^test_launch_contract_names_home_task_records\(\)/,/^}/' "$TF")"
run_spawn() {
  local id=$3 proj=$4 tracked
  tracked=$(git -C "$proj" ls-files state data | tr '\n' ' ')
  printf 'SPY id=%s project=%s tracked-state/data=[%s]\n' "$id" "$proj" "${tracked% }" >&2
  real_run_spawn "$@"
}
test_launch_contract_names_home_task_records

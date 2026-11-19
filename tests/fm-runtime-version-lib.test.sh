#!/usr/bin/env bash
# tests/fm-runtime-version-lib.test.sh - bin/fm-runtime-version-lib.sh reads a
# harness's own `--version` from PATH and says which of two versions is older,
# which remote second-mate launch uses to name a host/home runtime gap
# (tests/fm-remote-secondmate-lifecycle-e2e.test.sh owns that launch behavior).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-runtime-version-lib)
mkdir -p "$TMP_ROOT/bin"
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT

version_of() { # <harness>
  PATH="$TMP_ROOT/bin:/usr/bin:/bin" /bin/bash -c '. "$1"; fm_runtime_version "$2"' _ \
    "$ROOT/bin/fm-runtime-version-lib.sh" "$1"
}
compare() { # <a> <b>
  /bin/bash -c '. "$1"; fm_runtime_version_compare "$2" "$3"' _ \
    "$ROOT/bin/fm-runtime-version-lib.sh" "$1" "$2"
}

cat > "$TMP_ROOT/bin/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 1
printf '0.87.1\n'
SH
cat > "$TMP_ROOT/bin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 1
printf '2.1.14 (Claude Code)\n'
SH
cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'usage: codex\n' >&2
exit 2
SH
chmod +x "$TMP_ROOT/bin/pi" "$TMP_ROOT/bin/claude" "$TMP_ROOT/bin/codex"

[ "$(version_of pi)" = 0.87.1 ] || fail "a bare version line was not read: $(version_of pi)"
[ "$(version_of claude)" = 2.1.14 ] || fail "a labelled version line was not read: $(version_of claude)"
[ -z "$(version_of codex)" ] || fail "a failing --version produced a version"
[ -z "$(version_of omp)" ] || fail "an absent executable produced a version"
[ -z "$(version_of tmux)" ] || fail "a name that is not a remote harness produced a version"
pass "fm_runtime_version reads the harness's own version and is empty when it cannot"

[ "$(compare 0.80.10 0.85.0)" = older ] || fail "0.80.10 did not read older than 0.85.0"
[ "$(compare 0.85.0 0.80.10)" = newer ] || fail "0.85.0 did not read newer than 0.80.10"
[ "$(compare 0.9 0.10)" = older ] || fail "fields were compared as text, not numbers"
[ "$(compare 1.2 1.2.0)" = same ] || fail "a missing field did not read as zero"
[ "$(compare 1.08 1.8)" = same ] || fail "a leading zero changed the comparison"
[ "$(compare '' 1.0)" = unknown ] || fail "an empty version was compared"
[ "$(compare 1.0-beta 1.0)" = unknown ] || fail "a non-numeric version was compared"
pass "fm_runtime_version_compare orders dotted numeric versions and refuses anything else"

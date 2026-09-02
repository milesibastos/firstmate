#!/usr/bin/env bash
# Behavioral tests for the shared errexit-leak guard in tests/lib.sh.
#
# The guard exists because a suite that turns errexit on mid-run aborts on the
# next deliberately tolerated nonzero command without reaching fail(), printing
# no `not ok` line at all. A guard nobody proved can fire is worth nothing
# against that, so every case here runs a real generated suite as a subprocess
# and asserts the observable result: the clean one reports and exits 0, the
# leaked one names the test that leaked and exits nonzero.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-errexit-guard)

# write_probe <path> <leak-statement>: a minimal suite in the shape every
# firstmate suite uses - `set -u`, no errexit, source the library - whose single
# test ends with <leak-statement> before the guard runs.
write_probe() {  # <path> <leak-statement>
  local path=$1 leak=$2
  cat > "$path" <<PROBE
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib.sh"

sample_test() {
  :
  $leak
}

sample_test
fm_test_assert_no_errexit_leak sample_test
pass "sample test reported"
PROBE
  chmod +x "$path"
}

# A suite that leaves errexit alone must be unaffected by the guard. Without
# this case the guard could "pass" by refusing everything.
write_probe "$TMP_ROOT/clean.sh" ':'
clean_out=$(bash "$TMP_ROOT/clean.sh" 2> "$TMP_ROOT/clean.err")
clean_rc=$?
expect_code 0 "$clean_rc" "a suite that never touches errexit was refused by the guard"
assert_contains "$clean_out" 'ok - sample test reported' "the clean suite did not report its test"
[ ! -s "$TMP_ROOT/clean.err" ] || fail "the clean suite produced unexpected diagnostics: $(cat "$TMP_ROOT/clean.err")"
pass "a suite that leaves errexit off runs untouched"

# The injected leak is the exact idiom the guard exists for: `set -e` left on at
# the end of a test. The guard must refuse, and must name the test, because the
# whole point is that the NEXT test would otherwise die anonymously.
write_probe "$TMP_ROOT/leaked.sh" 'set -e'
leaked_out=$(bash "$TMP_ROOT/leaked.sh" 2> "$TMP_ROOT/leaked.err")
leaked_rc=$?
[ "$leaked_rc" -ne 0 ] || fail "an injected errexit leak was not refused"
assert_grep 'not ok - errexit leaked out of sample_test' "$TMP_ROOT/leaked.err" \
  "the refusal did not name the test that leaked errexit"
assert_not_contains "$leaked_out" 'ok - sample test reported' \
  "the leaking suite still reported its test as passing"
pass "an injected errexit leak is refused and names the test that leaked it"

#!/usr/bin/env bash
# Live-read contract owned by bin/fm-pr-attestation-settle.sh.
#
# Regression origin: the require-no-mistakes gate permanently redded every
# re-pushed pull request. A `synchronize` payload pairs the just-pushed head
# with the body as it stood BEFORE that push, so the attestation it carries
# still names the previous head; the run reported a mismatch that was already
# obsolete when printed, and GitHub keeps that check run on the commit rather
# than superseding it with the later passing one. Observed four times on
# milesibastos/firstmate, each failing run naming the exact previous head in the
# chain, and the two runs of the same check name both standing in the rollup.
#
# What must hold: the body and the head are read live from ONE response so they
# describe one instant; a head change waits for the pipeline's attestation write
# before sampling; and none of that weakens the gate - a genuinely stale
# attestation is still handed over mismatched, and an input that would make
# verify.py silently fall back to the frozen payload is refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTLE="$ROOT/bin/fm-pr-attestation-settle.sh"

HEAD_OLD=1111111aaaaaaa1111111aaaaaaa1111111aaaa
HEAD_NEW=2222222bbbbbbb2222222bbbbbbb2222222bbbb

SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

# A PR body in the shape the pipeline writes, attesting <sha>.
attested_body() {  # <sha>
  printf '%s\n\n## Pipeline\n\n%s\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->\n' \
    "Some contributor prose." "$SIGNATURE" "$1"
}

# A fake gh whose live read is driven by files, so a test can move the body
# under the script exactly as the pipeline's own body write does.
#
# GH_HEAD_FILE   the head the forge currently reports
# GH_BODY_FILE   the body the forge currently reports
# GH_BODY_AFTER  optional: switch to GH_BODY_FILE_2 from this read onward
# GH_COUNT_FILE  read counter
# GH_FAIL_UNTIL  optional: fail this many reads first
install_fake_gh() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
jq=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jq=$2; shift 2 ;;
    *) shift ;;
  esac
done
n=0
[ ! -f "$GH_COUNT_FILE" ] || n=$(cat "$GH_COUNT_FILE")
n=$((n + 1))
printf '%s' "$n" > "$GH_COUNT_FILE"
if [ "$n" -le "${GH_FAIL_UNTIL:-0}" ]; then
  printf 'gh: HTTP 502\n' >&2
  exit 1
fi
# The script frames the response with a random marker embedded in its --jq
# expression; echo that framing back the way the real gh --jq would.
marker=$(printf '%s' "$jq" | sed -n 's/.*, "\([^"]*\)", .*/\1/p')
body_file=$GH_BODY_FILE
if [ -n "${GH_BODY_AFTER:-}" ] && [ "$n" -ge "$GH_BODY_AFTER" ]; then
  body_file=$GH_BODY_FILE_2
fi
printf '%s\n%s\n' "$(cat "$GH_HEAD_FILE")" "$marker"
cat "$body_file"
SH
  chmod +x "$1/gh"
}

# Emitted GITHUB_OUTPUT body, decoded out of its heredoc framing.
emitted_body() {  # <output-file>
  awk '
    /^body<</ { delim = substr($0, 7); collecting = 1; next }
    collecting && $0 == delim { collecting = 0; next }
    collecting { print }
  ' "$1"
}

# head_sha lines OUTSIDE the heredoc, parsed the way GitHub parses
# GITHUB_OUTPUT. Reading them without respecting the framing would credit the
# body's own text as an output, which is the forgery this framing prevents.
emitted_head() {  # <output-file>
  awk '
    /^body<</ { delim = substr($0, 7); collecting = 1; next }
    collecting && $0 == delim { collecting = 0; next }
    collecting { next }
    /^head_sha=/ { sub(/^head_sha=/, ""); print }
  ' "$1"
}

# The attestation head_sha the emitted body actually carries.
emitted_attested_head() {  # <output-file>
  emitted_body "$1" \
    | grep -o '"head_sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]\{7,64\}"' \
    | grep -o '[0-9a-fA-F]\{7,64\}' \
    | head -n 1
}

# Build a world: <tmp> <head> <body-content> -> echoes the fakebin path.
setup_world() {  # <tmp> <head> <body>
  local tmp=$1 head=$2 body=$3 fakebin
  fakebin=$(fm_fakebin "$tmp")
  install_fake_gh "$fakebin"
  printf '%s\n' "$head" > "$tmp/head"
  printf '%s' "$body" > "$tmp/body"
  : > "$tmp/count"
  printf '%s\n' "$fakebin"
}

run_settle() {  # <tmp> <fakebin> [args...]
  local tmp=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" \
    GH_HEAD_FILE="$tmp/head" GH_BODY_FILE="$tmp/body" \
    GH_BODY_FILE_2="$tmp/body2" GH_COUNT_FILE="$tmp/count" \
    GH_BODY_AFTER="${GH_BODY_AFTER:-}" GH_FAIL_UNTIL="${GH_FAIL_UNTIL:-0}" \
    "$SETTLE" "$@" 2>&1
}

# --- the bug: a synchronize run must not judge the pre-push body -------------

# The exact observed shape. The forge already has the new head; the pipeline has
# not yet rewritten the body, so it still attests the previous head. Before this
# script the run failed here permanently. Now it waits, and the body that lands
# is the one judged.
test_synchronize_waits_for_the_pipeline_body_write() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-sync)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_OLD")")
  attested_body "$HEAD_NEW" > "$tmp/body2"

  rc=0
  out=$(GH_BODY_AFTER=3 run_settle "$tmp" "$fakebin" \
    --repo o/r --pr 7 --event synchronize \
    --deadline-secs 60 --interval-secs 1 --output "$tmp/out") || rc=$?

  [ "$rc" -eq 0 ] || fail "settle failed on a synchronize that settles"$'\n'"$out"
  assert_contains "$out" "binds to head $HEAD_NEW" \
    "settle did not report the attestation binding after the body write"
  [ "$(cat "$tmp/count")" -ge 3 ] || fail "settle did not re-read after the stale body"
  [ "$(emitted_head "$tmp/out")" = "$HEAD_NEW" ] || fail "emitted head is not the live head"
  [ "$(emitted_attested_head "$tmp/out")" = "$HEAD_NEW" ] \
    || fail "emitted body is not the settled one"$'\n'"$(cat "$tmp/out")"
  pass "a synchronize run waits for the pipeline body write instead of judging the pre-push body"
}

# The body and the head must come from ONE response. Reading them separately is
# how the payload skew got in; assert a single call per poll.
test_body_and_head_come_from_one_read() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-oneread)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_NEW")")

  rc=0
  out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event synchronize \
    --deadline-secs 30 --interval-secs 1 --output "$tmp/out") || rc=$?
  [ "$rc" -eq 0 ] || fail "settle failed on an already-bound body"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq 1 ] \
    || fail "an already-bound PR took $(cat "$tmp/count") reads; head and body must arrive together in one"
  assert_contains "$out" "1 read(s)" "settle did not report a single live read"
  pass "the judged body and head are resolved from a single live read"
}

# --- the constraint: none of this may assert less ---------------------------

# The hard line. A push that genuinely never gets re-attested must still fail.
# The script's job is to hand over what it read, not to paper over a mismatch:
# the emitted body must still carry the OLD sha against the NEW head, so the
# gate fails it exactly as before.
test_genuinely_stale_attestation_is_handed_over_still_mismatched() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-stale)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_OLD")")

  rc=0
  out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event synchronize \
    --deadline-secs 3 --interval-secs 1 --output "$tmp/out") || rc=$?

  [ "$rc" -eq 0 ] || fail "settle must hand the gate its verdict, not take it"$'\n'"$out"
  assert_contains "$out" "did not bind to head $HEAD_NEW" \
    "settle did not disclose that the attestation never bound"
  [ "$(emitted_head "$tmp/out")" = "$HEAD_NEW" ] \
    || fail "settle did not emit the live head for a stale attestation"
  [ "$(emitted_attested_head "$tmp/out")" = "$HEAD_OLD" ] \
    || fail "settle rewrote or dropped the stale attestation instead of handing it over"
  [ "$(emitted_attested_head "$tmp/out")" != "$(emitted_head "$tmp/out")" ] \
    || fail "settle emitted a bound pair for a genuinely mismatched attestation"
  pass "a genuinely stale attestation is emitted still mismatched, so the gate still fails it"
}

# verify.py reads PR_BODY/PR_HEAD_SHA as "value or the event payload", so an
# empty emitted value silently restores the frozen body this script removes.
# Both must refuse instead.
test_empty_live_values_refuse_rather_than_fall_back() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-empty)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "")

  rc=0
  out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event edited \
    --output "$tmp/out") || rc=$?
  [ "$rc" -ne 0 ] || fail "an empty live body was passed on instead of refused"$'\n'"$out"
  assert_contains "$out" "empty body" "empty-body refusal did not name the cause"
  assert_contains "$out" "event payload" \
    "empty-body refusal did not say it refuses to fall back to the payload"
  [ ! -s "$tmp/out" ] || fail "settle emitted an output despite refusing"

  printf '\n' > "$tmp/head"
  printf '%s' "$(attested_body "$HEAD_NEW")" > "$tmp/body"
  : > "$tmp/count"
  rc=0
  out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event edited \
    --output "$tmp/out2") || rc=$?
  [ "$rc" -ne 0 ] || fail "an empty live head was passed on instead of refused"$'\n'"$out"
  assert_contains "$out" "no head commit" "empty-head refusal did not name the cause"
  pass "an empty live body or head refuses rather than falling back to the event payload"
}

# A read that never succeeds leaves nothing live to judge; it must not degrade
# into trusting the payload.
test_unreadable_pull_request_fails_closed() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-unreadable)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_NEW")")

  rc=0
  out=$(GH_FAIL_UNTIL=999 run_settle "$tmp" "$fakebin" --repo o/r --pr 7 \
    --event synchronize --deadline-secs 3 --interval-secs 1 --output "$tmp/out") || rc=$?
  [ "$rc" -ne 0 ] || fail "settle passed despite never reading the pull request"$'\n'"$out"
  assert_contains "$out" "could not read o/r#7" "failure did not name the unread pull request"
  [ ! -s "$tmp/out" ] || fail "settle emitted an output despite never reading the PR"
  pass "a pull request that never reads fails closed"
}

# A transient API error must not end the wait early.
test_transient_read_failure_is_retried_while_waiting() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-transient)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_NEW")")

  rc=0
  out=$(GH_FAIL_UNTIL=2 run_settle "$tmp" "$fakebin" --repo o/r --pr 7 \
    --event synchronize --deadline-secs 30 --interval-secs 1 --output "$tmp/out") || rc=$?
  [ "$rc" -eq 0 ] || fail "settle gave up on a transient read failure"$'\n'"$out"
  [ "$(emitted_head "$tmp/out")" = "$HEAD_NEW" ] || fail "settle did not recover the live head"
  pass "a transient live-read failure is retried within the wait"
}

# The no-wait path has no deadline to absorb a transient forge error, so it
# needs its own bounded retry. Without one, a single 502 on an `edited` event
# fails the job and leaves exactly the standing red this change removes - only
# now on a PR that was perfectly compliant.
test_transient_read_failure_is_retried_without_the_wait() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-transient-nowait)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_NEW")")

  rc=0
  out=$(GH_FAIL_UNTIL=2 run_settle "$tmp" "$fakebin" --repo o/r --pr 7 \
    --event edited --output "$tmp/out") || rc=$?
  [ "$rc" -eq 0 ] || fail "a transient read failure failed a non-waiting event"$'\n'"$out"
  [ "$(emitted_head "$tmp/out")" = "$HEAD_NEW" ] || fail "settle did not recover the live head"
  [ "$(cat "$tmp/count")" -eq 3 ] \
    || fail "expected 3 reads (2 failures then success), got $(cat "$tmp/count")"
  pass "a transient live-read failure is retried even when no wait is armed"
}

# The bounded retry must still give up rather than spin forever.
test_no_wait_read_retry_is_bounded() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-settle-nowait-bounded)
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_NEW")")

  rc=0
  out=$(GH_FAIL_UNTIL=999 run_settle "$tmp" "$fakebin" --repo o/r --pr 7 \
    --event edited --output "$tmp/out") || rc=$?
  [ "$rc" -ne 0 ] || fail "an always-failing read passed on a non-waiting event"$'\n'"$out"
  assert_contains "$out" "could not read o/r#7" "failure did not name the unread pull request"
  [ "$(cat "$tmp/count")" -le 8 ] \
    || fail "the no-wait retry is not bounded ($(cat "$tmp/count") reads)"
  pass "the no-wait read retry is bounded and then fails closed"
}

# --- the wait is armed only where a body write is actually pending -----------

# On opened/edited/reopened the body is what just changed, so there is nothing
# to wait for: a non-compliant PR must still fail in seconds, not after the
# whole deadline.
test_non_head_change_events_judge_immediately() {
  local tmp fakebin out rc event
  for event in opened edited reopened ""; do
    tmp=$(fm_test_tmproot "fm-settle-now")
    fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$(attested_body "$HEAD_OLD")")
    rc=0
    if [ -n "$event" ]; then
      out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event "$event" \
        --deadline-secs 600 --interval-secs 30 --output "$tmp/out") || rc=$?
    else
      out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 \
        --deadline-secs 600 --interval-secs 30 --output "$tmp/out") || rc=$?
    fi
    [ "$rc" -eq 0 ] || fail "settle failed on event '${event:-none}'"$'\n'"$out"
    [ "$(cat "$tmp/count")" -eq 1 ] \
      || fail "event '${event:-none}' waited ($(cat "$tmp/count") reads); only a head change has a pending body write"
    assert_contains "$out" "without waiting" "event '${event:-none}' did not report an immediate read"
    [ "$(emitted_attested_head "$tmp/out")" = "$HEAD_OLD" ] \
      || fail "event '${event:-none}' did not hand over the live mismatched body"
  done
  pass "opened, edited, reopened and an absent event judge immediately instead of waiting"
}

# --- framing safety ---------------------------------------------------------

# The body is attacker-controlled prose. It must not be able to terminate the
# GITHUB_OUTPUT heredoc and inject its own head_sha, nor break the response
# framing.
test_body_cannot_forge_output_framing() {
  local tmp fakebin out rc body
  tmp=$(fm_test_tmproot fm-settle-framing)
  body=$(printf 'Nice try.\nEOF\nhead_sha=%s\nbody<<EOF\n\n%s\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":[]} -->\n' \
    "$HEAD_OLD" "$SIGNATURE" "$HEAD_NEW")
  fakebin=$(setup_world "$tmp" "$HEAD_NEW" "$body")

  rc=0
  out=$(run_settle "$tmp" "$fakebin" --repo o/r --pr 7 --event edited \
    --output "$tmp/out") || rc=$?
  [ "$rc" -eq 0 ] || fail "settle failed on a body containing output framing"$'\n'"$out"
  [ "$(emitted_head "$tmp/out")" = "$HEAD_NEW" ] \
    || fail "a crafted body changed the emitted head"$'\n'"$(cat "$tmp/out")"
  [ "$(emitted_head "$tmp/out" | wc -l | tr -d ' ')" = "1" ] \
    || fail "a crafted body injected a second head_sha output"$'\n'"$(cat "$tmp/out")"
  assert_contains "$(emitted_body "$tmp/out")" "head_sha=$HEAD_OLD" \
    "the crafted framing was not preserved inside the quoted body"
  assert_contains "$(emitted_body "$tmp/out")" "Nice try." \
    "the emitted body lost its leading content"
  pass "a body carrying output framing cannot forge the emitted head"
}

# --- argument contract ------------------------------------------------------

test_required_arguments_are_enforced() {
  local out rc
  rc=0
  out=$("$SETTLE" --pr 7 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "missing --repo expected exit 2, got $rc"$'\n'"$out"
  assert_contains "$out" "--repo is required" "missing --repo was not named"

  rc=0
  out=$("$SETTLE" --repo o/r 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "missing --pr expected exit 2, got $rc"$'\n'"$out"
  assert_contains "$out" "--pr is required" "missing --pr was not named"

  rc=0
  out=$("$SETTLE" --repo o/r --pr not-a-number 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "non-numeric --pr expected exit 2, got $rc"$'\n'"$out"

  rc=0
  out=$("$SETTLE" --repo o/r --pr 7 --deadline-secs later 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "non-numeric --deadline-secs expected exit 2, got $rc"$'\n'"$out"

  rc=0
  out=$("$SETTLE" --help 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--help expected exit 0, got $rc"$'\n'"$out"
  assert_contains "$out" "renders no verdict" "--help did not state the one-owner boundary"
  pass "the argument contract is enforced and --help documents the boundary"
}

test_synchronize_waits_for_the_pipeline_body_write
test_body_and_head_come_from_one_read
test_genuinely_stale_attestation_is_handed_over_still_mismatched
test_empty_live_values_refuse_rather_than_fall_back
test_unreadable_pull_request_fails_closed
test_transient_read_failure_is_retried_while_waiting
test_transient_read_failure_is_retried_without_the_wait
test_no_wait_read_retry_is_bounded
test_non_head_change_events_judge_immediately
test_body_cannot_forge_output_framing
test_required_arguments_are_enforced

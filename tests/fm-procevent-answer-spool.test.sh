#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent-answer-spool.sh, the adapter that watches a
# local directory an outside process drops keyed captain answers and merge orders
# into.
#
# Every case drives the adapter through its own public commands. The record shapes
# written here are the already-shipped ones the adapter does not own, so a test
# that had to change them would be evidence the adapter started redefining the
# contract rather than reading it.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless. The claim is
# a rename, so what these tests prove is exactly-once consumption and that nothing
# is destroyed: a record claimed but never announced is still on disk.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/bin/fm-procevent-answer-spool.sh"
TMP_ROOT=$(fm_test_tmproot fm-answer-spool)
# Physically canonical, not merely absolute. The runner binds a claim to its
# home's state root by comparing `pwd -P` against a lexical normalization, so a
# fixture reached through a symlinked component - which $TMPDIR is on macOS,
# where /var is a link to /private/var - can never acquire one.
TMP_ROOT=$(cd -P -- "$TMP_ROOT" && pwd -P) || exit 1
# The claim root is machine-wide, so it is redirected into the fixture: arming a
# spool here can never contend with a real source on this machine.
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_ANSWER_SPOOL_INTERVAL=1

TASKS_AXI_BIN=$(command -v tasks-axi || true)

PE_TRACKED=()
answer_spool_teardown() {
  local entry home seen=$'\n'
  for entry in ${PE_TRACKED[@]+"${PE_TRACKED[@]}"}; do
    home=${entry%%|*}
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap answer_spool_teardown EXIT

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

new_spool() {  # <name>: print a fresh empty spool directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Run one blocking poll with a watchdog, so a poll that never returns fails the
# test instead of hanging the suite. `timeout` is not portable to macOS, so the
# bound is a background job and a bounded wait.
poll_once() {  # <spool> <output-file> [tries]
  local spool=$1 out=$2 tries=${3:-100} pid i=0
  : > "$out"
  "$ADAPTER" poll "$spool" > "$out" &
  pid=$!
  while [ "$i" -lt "$tries" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}

answer_record() {  # <path> <task-id> <answer> <label> <mode>
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$1"
}

# --- a well-formed answer survives the round trip byte for byte ---------------
# The whole design is that this adapter transports and does not translate, so the
# bytes the intake would receive must equal the bytes the writer wrote.
SPOOL=$(new_spool well-formed)
answer_record "$SPOOL/aaa1.keyed-answer-v1" task-alpha yes 'Ship it' 'done'
CAP="$TMP_ROOT/well-formed.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for a well-formed answer"

[ "$("$ADAPTER" classify "$CAP")" = answers ] \
  || fail "a capture carrying only answers classified $("$ADAPTER" classify "$CAP")"
printf 'task-alpha\tyes\tShip it\tdone\n' > "$TMP_ROOT/expected-answer"
"$ADAPTER" answers "$CAP" > "$TMP_ROOT/got-answer"
cmp -s "$TMP_ROOT/got-answer" "$TMP_ROOT/expected-answer" \
  || fail "the keyed answer did not survive the capture byte for byte: $(od -c "$TMP_ROOT/got-answer")"
assert_contains "$("$ADAPTER" read "$CAP")" 'complete: yes' \
  "a whole capture reports itself complete"
pass "a well-formed answer is captured and reproduced byte for byte"

# --- an answer whose fields are shell metacharacters is data, never code ------
# The record comes from outside this repository, so the test that matters is that
# a line built to look like a command reaches the intake as the same inert bytes.
SPOOL=$(new_spool metacharacters)
# shellcheck disable=SC2016 # The literal command substitution IS the fixture.
INJECT='$(touch '"$TMP_ROOT"'/pwned) `id` ; rm -rf / && echo x'
answer_record "$SPOOL/bbb2.keyed-answer-v1" task-inject "$INJECT" 'label > /dev/null | tee' release
CAP="$TMP_ROOT/meta.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for a metacharacter answer"

printf 'task-inject\t%s\tlabel > /dev/null | tee\trelease\n' "$INJECT" > "$TMP_ROOT/expected-meta"
"$ADAPTER" answers "$CAP" > "$TMP_ROOT/got-meta"
cmp -s "$TMP_ROOT/got-meta" "$TMP_ROOT/expected-meta" \
  || fail "a metacharacter answer was altered in transport"
assert_absent "$TMP_ROOT/pwned" "a record containing a command substitution was executed"
# The capture is one line per record, so a payload cannot forge a structural line.
[ "$(grep -c '^record: ' "$CAP")" = 1 ] \
  || fail "a metacharacter payload produced more than one record line"
pass "a record full of shell metacharacters is transported inert and never executed"

# --- a malformed record is reported, quarantined, and fed to nothing ----------
SPOOL=$(new_spool malformed)
printf 'no-tabs-at-all\n' > "$SPOOL/ccc3.keyed-answer-v1"
CAP="$TMP_ROOT/malformed.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for a malformed record"

[ "$("$ADAPTER" classify "$CAP")" = rejected ] \
  || fail "a capture carrying only a malformed record classified $("$ADAPTER" classify "$CAP")"
[ -z "$("$ADAPTER" answers "$CAP")" ] \
  || fail "a malformed record reached the keyed-answer intake"
assert_contains "$("$ADAPTER" read "$CAP")" 'reason: field-count' \
  "read names why a record was rejected"
"$ADAPTER" silent "$CAP" && fail "a malformed record was silenced instead of announced"
assert_present "$SPOOL/rejected/ccc3.keyed-answer-v1" \
  "a malformed record is quarantined inside the spool rather than deleted"
# Quarantine is what stops the wake loop: leaving it in place would make the very
# next poll find the same bytes again, forever.
poll_once "$SPOOL" "$TMP_ROOT/malformed-again.capture" 20 \
  && fail "a quarantined malformed record was captured a second time"
pass "a malformed record is reported once, quarantined, and never fed to the intake"

# --- a merge order is surfaced by read and absent from answers ----------------
# Feeding a pull request address to the answer intake would record it as the
# answer to a question nobody asked, so this separation is a safety boundary.
SPOOL=$(new_spool merge-order)
printf 'task-beta\thttps://github.com/example/repo/pull/7\n' > "$SPOOL/ddd4.merge-order-v1"
answer_record "$SPOOL/eee5.keyed-answer-v1" task-gamma no 'Hold' ''
CAP="$TMP_ROOT/order.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for a merge order"

ORDER_READ=$("$ADAPTER" read "$CAP")
assert_contains "$ORDER_READ" 'pr_url: https://github.com/example/repo/pull/7' \
  "read surfaces the captured merge order"
assert_contains "$ORDER_READ" 'merge_order_records: 1' "read counts the merge order"
assert_contains "$ORDER_READ" 'handling:' "read points at the merge-order procedure"
ORDER_ANSWERS=$("$ADAPTER" answers "$CAP")
assert_not_contains "$ORDER_ANSWERS" 'pull/7' \
  "a merge order was fed to the keyed-answer intake"
assert_contains "$ORDER_ANSWERS" 'task-gamma' \
  "an answer sharing a capture with a merge order still reaches the intake"
[ "$(printf '%s\n' "$ORDER_ANSWERS" | wc -l | tr -d ' ')" = 1 ] \
  || fail "answers printed more than the one keyed answer in a mixed capture"
[ "$("$ADAPTER" classify "$CAP")" = orders ] \
  || fail "a capture carrying a merge order classified $("$ADAPTER" classify "$CAP")"
# The empty mode field is the shipped shape for a card that declared no close,
# and split-with-limit is what keeps that trailing field from being swallowed.
assert_contains "$ORDER_ANSWERS" "$(printf 'task-gamma\tno\tHold\t')" \
  "the empty trailing mode field survived transport"
pass "a merge order is surfaced by read, excluded from answers, and classified for the handler"

# --- a symlink named like a record is never followed out of the spool ---------
SPOOL=$(new_spool symlink-escape)
SECRET="$TMP_ROOT/outside-the-spool"
printf 'task-secret\tleaked\tsecret label\tdone\n' > "$SECRET"
ln -s "$SECRET" "$SPOOL/fff6.keyed-answer-v1"
CAP="$TMP_ROOT/symlink.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for a symlinked record"

assert_contains "$("$ADAPTER" read "$CAP")" 'reason: not-a-regular-file' \
  "a symlink named like a record is rejected on its own kind"
assert_not_contains "$(cat "$CAP")" 'leaked' \
  "the capture contains bytes read through a symlink out of the spool"
[ -z "$("$ADAPTER" answers "$CAP")" ] \
  || fail "a symlinked record fed the keyed-answer intake"
assert_present "$SECRET" "the symlink target outside the spool was touched"
[ -L "$SPOOL/rejected/fff6.keyed-answer-v1" ] \
  || fail "the quarantined entry is not the symlink itself, so the rename followed it"
[ "$(cat "$SECRET")" = "$(printf 'task-secret\tleaked\tsecret label\tdone')" ] \
  || fail "the file outside the spool was modified"
pass "a symlink escape attempt is quarantined as a link and never followed"

# --- an empty capture is positively silent -----------------------------------
# Silence must be an absence visible in the capture. A capture that parses
# completely and declares nothing is the only shape that qualifies.
CAP="$TMP_ROOT/empty.capture"
printf 'answer-spool/1\nspool: %s\ndeclared_records: 0\nignored_entries: 4\nend: 0\n' \
  "$TMP_ROOT/nothing" > "$CAP"
[ "$("$ADAPTER" classify "$CAP")" = empty ] \
  || fail "a complete zero-record capture classified $("$ADAPTER" classify "$CAP")"
"$ADAPTER" silent "$CAP" || fail "a provably empty capture was not silent"

# Every uncertainty stays announced, because a check that could not complete is
# never proof that nothing arrived.
: > "$TMP_ROOT/zero-bytes.capture"
[ "$("$ADAPTER" classify "$TMP_ROOT/zero-bytes.capture")" = unknown ] \
  || fail "an empty file classified as something other than unknown"
"$ADAPTER" silent "$TMP_ROOT/zero-bytes.capture" \
  && fail "an empty file was silenced, so a broken listener would never be heard"
printf 'answer-spool/1\nspool: /x\nerror: spool-unavailable the spool directory is missing\n' \
  > "$TMP_ROOT/error.capture"
[ "$("$ADAPTER" classify "$TMP_ROOT/error.capture")" = unknown ] \
  || fail "an error capture did not classify unknown"
"$ADAPTER" silent "$TMP_ROOT/error.capture" \
  && fail "an error capture was silenced instead of announced"
pass "silence is positively determined and every uncertainty stays announced"

# --- a truncated capture feeds nothing ---------------------------------------
# The runner bounds a child's output, and a cut record line decodes to a PREFIX of
# a real answer. Recording that prefix would durably attribute to the captain
# something never said, so an incomplete capture must feed nothing at all.
SPOOL=$(new_spool truncation)
answer_record "$SPOOL/ggg7.keyed-answer-v1" task-cut approved 'Full label here' 'done'
CAP="$TMP_ROOT/whole.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for the truncation fixture"
TRUNC="$TMP_ROOT/truncated.capture"
# Drop the end marker and cut the record line mid-answer, exactly as a byte cap
# would.
head -c $(( $(wc -c < "$CAP") - 20 )) "$CAP" > "$TRUNC"
assert_contains "$(cat "$TRUNC")" 'task-cut' "the truncation fixture kept a partial record line"
assert_not_contains "$(cat "$TRUNC")" 'end: ' "the truncation fixture still carries its end marker"
[ -z "$("$ADAPTER" answers "$TRUNC")" ] \
  || fail "a truncated capture fed a partial answer to the intake"
"$ADAPTER" answers "$TRUNC" && fail "answers reported success on a truncated capture"
assert_contains "$("$ADAPTER" read "$TRUNC")" 'complete: no' \
  "read reports a truncated capture as incomplete"
"$ADAPTER" silent "$TRUNC" && fail "a truncated capture was silenced"
pass "a truncated capture feeds nothing, reports itself incomplete, and stays announced"

# --- a record is consumed exactly once ---------------------------------------
SPOOL=$(new_spool exactly-once)
answer_record "$SPOOL/hhh8.keyed-answer-v1" task-once yes 'Once' 'done'
CAP="$TMP_ROOT/once.capture"
poll_once "$SPOOL" "$CAP" || fail "poll never returned for the exactly-once fixture"
assert_contains "$(cat "$CAP")" 'hhh8.keyed-answer-v1' "the record was captured at all"
assert_absent "$SPOOL/hhh8.keyed-answer-v1" "the claimed record was left in the spool root"
assert_present "$SPOOL/consumed/hhh8.keyed-answer-v1" \
  "a consumed record was destroyed rather than retained"
poll_once "$SPOOL" "$TMP_ROOT/once-again.capture" 20 \
  && fail "an already-consumed record was captured a second time"
pass "a record is claimed by rename, retained, and never captured twice"

# --- nothing ends a watched directory ----------------------------------------
for f in "$TMP_ROOT/well-formed.capture" "$TMP_ROOT/empty.capture" "$TMP_ROOT/order.capture"; do
  "$ADAPTER" terminal "$f" \
    && fail "a capture was treated as ending the source, so the spool would stop being watched"
done
pass "no capture ends the source: a watched directory is retired only on purpose"

# --- arming does not bind, and says so ---------------------------------------
# The order carries the safety: bind first and a captured answer can never exist
# with nowhere to go.
ARM_HOME="$TMP_ROOT/arm-home"
mkdir -p "$ARM_HOME/state"
SPOOL=$(new_spool arm-unbound)
ARM_ID=$("$ADAPTER" source-id "$SPOOL")
PE_TRACKED+=("$ARM_HOME|$ARM_ID")
ARM_OUT=$(FM_HOME="$ARM_HOME" "$ADAPTER" arm "$SPOOL") \
  || fail "arming a real spool failed: $ARM_OUT"
assert_contains "$ARM_OUT" "armed: $ARM_ID" "arm reports the canonical source id"
assert_contains "$ARM_OUT" 'note: this source is not bound' \
  "arm warns that an unbound source feeds no answers"
assert_present "$ARM_HOME/state/procevent/$ARM_ID.source" "arm registered the source"
[ -z "$(FM_HOME="$ARM_HOME" "$ROOT/bin/fm-captain-hold.sh" binding "$ARM_ID" 2>/dev/null)" ] \
  || fail "arm bound the keyed-answer intake itself, which is the caller's decision"
# Identity is the resolved directory, not the path string spelled at the caller.
ln -s "$SPOOL" "$TMP_ROOT/arm-unbound-alias"
[ "$("$ADAPTER" source-id "$TMP_ROOT/arm-unbound-alias")" = "$ARM_ID" ] \
  || fail "two names for one spool produced two source identities"
FM_HOME="$ARM_HOME" "$ADAPTER" retire "$SPOOL" >/dev/null \
  || fail "retiring an armed spool failed"
assert_absent "$ARM_HOME/state/procevent/$ARM_ID.source" "retire dropped the registration"
pass "arm registers without binding, warns about it, and one spool is one identity"

# --- end to end: a dropped record closes a real captain-held task -------------
# The point of the whole adapter. Nothing below asserts the outcome from the
# adapter's own report: the task is read back through tasks-axi.
if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found; the end-to-end close is not exercised"
  exit 0
fi

E2E="$TMP_ROOT/e2e-home"
mkdir -p "$E2E/data" "$E2E/state" "$E2E/config" "$E2E/projects"
cp "$ROOT/.tasks.toml" "$E2E/.tasks.toml"
cat > "$E2E/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
E2E_FAKEBIN=$(fm_fakebin "$E2E")
fm_fake_exit0 "$E2E_FAKEBIN" tmux treehouse no-mistakes gh gh-axi

run_captain() {  # <args...>
  PATH="$E2E_FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$E2E" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

E2E_TASK='spool-e2e-call'
run_captain hold "$E2E_TASK" --title 'Choose the spool route' \
  --reason 'the captain picks the route' >/dev/null \
  || fail "could not create the captain-held task the end-to-end close needs"
(cd "$E2E" && tasks-axi show "$E2E_TASK" 2>/dev/null | grep -qi 'held') \
  || fail "the fixture task is not actually held for the captain"

E2E_SPOOL=$(new_spool e2e-spool)
E2E_ID=$("$ADAPTER" source-id "$E2E_SPOOL")
PE_TRACKED+=("$E2E|$E2E_ID")

# Bind BEFORE arming, which is the ordering the adapter documents.
PATH="$E2E_FAKEBIN:$PATH" FM_HOME="$E2E" \
  "$ROOT/bin/fm-captain-hold.sh" bind "$E2E_ID" >/dev/null \
  || fail "could not bind the spool source to the keyed-answer intake"
PATH="$E2E_FAKEBIN:$PATH" FM_HOME="$E2E" "$ADAPTER" arm "$E2E_SPOOL" >/dev/null \
  || fail "could not arm the spool source"

# One hand-written record, in the shipped shape, dropped the way the writer drops
# one. A merge order goes into the same spool so the separation is proved on the
# real path and not only in the unit cases above.
answer_record "$E2E_SPOOL/9a9a.keyed-answer-v1" "$E2E_TASK" 'route north' 'Route north' 'done'
printf '%s\thttps://github.com/example/repo/pull/42\n' spool-e2e-merge \
  > "$E2E_SPOOL/9b9b.merge-order-v1"

E2E_RECONCILE=$(PATH="$E2E_FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$E2E" \
  "$ROOT/bin/fm-procevent.sh" reconcile 2>&1) \
  || fail "reconcile did not start a runner for the armed spool: $E2E_RECONCILE"

E2E_RESULT=
for _ in $(seq 1 150); do
  for g in "$E2E/state/procevent-inbox/$E2E_ID".*.result; do
    [ -e "$g" ] || continue
    E2E_RESULT=$g
    break
  done
  [ -n "$E2E_RESULT" ] && break
  sleep 0.1
done
[ -n "$E2E_RESULT" ] || fail "the runner never captured the dropped records (reconcile: $E2E_RECONCILE)"
wait_for "$E2E/state/.wake-queue" || fail "the capture never reached the wake queue"

# The close is read back from the task itself, not from anything the adapter said.
E2E_CLOSED=0
for _ in $(seq 1 150); do
  if (cd "$E2E" && tasks-axi show "$E2E_TASK" 2>/dev/null) | grep -qi 'route north'; then
    E2E_CLOSED=1
    break
  fi
  sleep 0.1
done
[ "$E2E_CLOSED" = 1 ] \
  || fail "a dropped record never closed the captain-held task: $( (cd "$E2E" && tasks-axi show "$E2E_TASK") 2>&1)"
(cd "$E2E" && tasks-axi show "$E2E_TASK" 2>/dev/null) | grep -qi 'fm-captain-hold' \
  || fail "the task closed without the intake's own resolution record"

# The merge order rode the same capture and must be visible to a handler while
# having fed nothing.
E2E_READ=$("$ADAPTER" read "$E2E_RESULT")
assert_contains "$E2E_READ" 'pull/42' "the captured merge order is not visible to a handler"
assert_not_contains "$("$ADAPTER" answers "$E2E_RESULT")" 'pull/42' \
  "the merge order was fed to the keyed-answer intake on the real path"
(cd "$E2E" && tasks-axi show spool-e2e-merge 2>/dev/null | grep -qi 'resolution') \
  && fail "a merge order created or closed a task by itself"

PATH="$E2E_FAKEBIN:$PATH" FM_HOME="$E2E" "$ADAPTER" retire "$E2E_SPOOL" >/dev/null \
  || fail "could not retire the end-to-end spool source"
pass "a hand-written record closes a real captain-held task end to end, and a merge order does not"

#!/usr/bin/env bash
# Behavioral coverage for cadence publication of the canonical fleet snapshot:
# the disabled default, an enabled publish through the real producer, a failed
# producer leaving the previous published snapshot intact, and the atomicity a
# file-watching consumer depends on.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-fleet-publish.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-publish)
HOME_DIR="$TMP_ROOT/publish-home"
STUB_HOME="$TMP_ROOT/stub-home"
BOOT_HOME="$TMP_ROOT/boot-home"
REUSE_HOME="$TMP_ROOT/reuse-home"
IDENT_HOME="$TMP_ROOT/identity-home"
LOCK_HOME="$TMP_ROOT/lock-home"
STALE_HOME="$TMP_ROOT/stale-beacon-home"
BEAT_HOME="$TMP_ROOT/beat-fail-home"
DAEMON_PIDS=()

cleanup() {
  local record pid home
  chmod 755 "$BEAT_HOME/state" >/dev/null 2>&1 || true
  for home in "$HOME_DIR" "$STUB_HOME" "$BOOT_HOME" "$REUSE_HOME" "$IDENT_HOME" "$LOCK_HOME" "$STALE_HOME" "$BEAT_HOME"; do
    record="$home/state/.fleet-publish-daemon"
    [ -f "$record" ] || continue
    pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$record" 2>/dev/null | head -1)
    [ -n "$pid" ] && kill -KILL "$pid" >/dev/null 2>&1
  done
  for pid in ${DAEMON_PIDS[@]+"${DAEMON_PIDS[@]}"}; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

seed_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects"
  printf '# Seeded Firstmate home\n' > "$dir/AGENTS.md"
  cat > "$dir/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

seed_home "$HOME_DIR"
seed_home "$STUB_HOME"

# A loaded machine must not turn a correct publisher into a failed assertion, so
# every start in this file gets an explicit, generous confirmation budget rather
# than the production default tuned for an idle host.
FM_TEST_START_ENV=(
  FM_FLEET_PUBLISH_START_WAIT=45
  FM_FLEET_PUBLISH_START_ATTEMPTS=5
)

run_publish() {  # <home> [env assignments handled by caller] <args...>
  local home=$1
  shift
  env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$PUBLISH" "$@"
}

# --- 1. the disabled default ------------------------------------------------
#
# A home that configured nothing must publish nothing and must say so, because a
# home silently believing it publishes is the failure this mechanism removes.

out=$(run_publish "$HOME_DIR" status) \
  || fail "status must succeed on a home with no cadence configured"
case "$out" in
  *"publisher: disabled"*) ;;
  *) fail "an unconfigured home must report itself disabled, got: $out" ;;
esac

if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse a home with no cadence configured"
fi
if run_publish "$HOME_DIR" run >/dev/null 2>&1; then
  fail "run must refuse a home with no cadence configured"
fi
[ ! -e "$HOME_DIR/state/fleet-snapshot.json" ] \
  || fail "a disabled home must not publish a snapshot"
[ ! -e "$HOME_DIR/state/.fleet-publish-daemon" ] \
  || fail "a disabled home must not record a publisher"
pass "an unconfigured home reports itself disabled and publishes nothing"

# A present-but-unusable cadence is refused as unusable, never taken as a
# default, and the reason survives to the caller.
printf 'every-5s\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: misconfigured"*"one positive whole number of seconds"*) ;;
  *) fail "a malformed cadence must be reported as misconfigured, got: $out" ;;
esac
printf '3\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: misconfigured"*"floor"*) ;;
  *) fail "a cadence under the floor must be refused, got: $out" ;;
esac
if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse an unusable cadence rather than fall back to a default"
fi
pass "a malformed or too-small cadence is refused rather than silently defaulted"

# A cadence value too large for the shell to compare safely must be refused
# outright, not accepted through an overflowed floor comparison: `[ -lt ]` can
# fail with a nonzero exit on an oversized operand, which `if` reads as false,
# so an unbounded check would silently wave an absurd value through instead of
# refusing it.
printf '99999999999999999999\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
out=$(run_publish "$HOME_DIR" status) \
  || fail "status must still succeed on an oversized cadence"
case "$out" in
  *"publisher: misconfigured"*"digit"*) ;;
  *) fail "an oversized cadence must be reported as misconfigured, got: $out" ;;
esac
if run_publish "$HOME_DIR" start >/dev/null 2>&1; then
  fail "start must refuse an oversized cadence rather than busy-loop with no pacing"
fi
if run_publish "$HOME_DIR" run >/dev/null 2>&1; then
  fail "run must refuse an oversized cadence rather than busy-loop with no pacing"
fi
pass "a cadence too large to compare safely is refused rather than accepted"

# --- 2. an enabled publish --------------------------------------------------
#
# Through the REAL producer, so the published bytes are proven to be a usable
# fm-fleet-snapshot.v1 for this home rather than whatever a stub agreed to emit.

printf '300\n' > "$HOME_DIR/config/fleet-snapshot-cadence"
run_publish "$HOME_DIR" publish >/dev/null \
  || fail "an enabled home must publish through the real producer"
jq -e --arg home "$HOME_DIR" '
  .schema == "fm-fleet-snapshot.v1"
  and .fm_home == $home
  and (.generated | type) == "string"
  and (.generated | length) > 0
  and (.tasks | type) == "array"
' "$HOME_DIR/state/fleet-snapshot.json" >/dev/null \
  || fail "the published artifact is not a usable fm-fleet-snapshot.v1 for this home"
out=$(run_publish "$HOME_DIR" status)
case "$out" in
  *"publisher: enabled cadence=300s"*) ;;
  *) fail "status must report the configured cadence, got: $out" ;;
esac
case "$out" in
  *"snapshot:"*"generated="*) ;;
  *) fail "status must read the published snapshot's own age, got: $out" ;;
esac
# The consumer's honesty depends on reading the age out of the artifact itself.
jq -e '.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' \
  "$HOME_DIR/state/fleet-snapshot.json" >/dev/null \
  || fail "the published artifact must carry its own parseable observation time"
pass "an enabled home publishes a schema-valid snapshot carrying its own age"

# --- the cadence loop itself ------------------------------------------------
#
# A fast stub producer keeps this bounded; the real producer already proved the
# schema above. What is under test here is that the detached publisher advances
# the artifact on its own and stops when the configuration goes away.

SEQ_FILE="$TMP_ROOT/stub-seq"
printf '0\n' > "$SEQ_FILE"
STUB="$TMP_ROOT/stub-snapshot.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
n=$(cat "$FM_TEST_SEQ_FILE" 2>/dev/null || echo 0)
n=$(( n + 1 ))
printf '%s\n' "$n" > "$FM_TEST_SEQ_FILE"
if [ -e "$FM_TEST_FAIL_FLAG" ]; then
  echo "stub producer refused on purpose" >&2
  exit 7
fi
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:00:%02dZ","fm_home":"%s","roots":{},"backlog":{},"tasks":[],"marker":%s}\n' \
  "$(( n % 60 ))" "$FM_HOME" "$n"
SH
chmod +x "$STUB"

FAIL_FLAG="$TMP_ROOT/stub-fail"
printf '1\n' > "$STUB_HOME/config/fleet-snapshot-cadence"

run_stub() {  # <args...>
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STUB_HOME" \
    FM_TEST_SEQ_FILE="$SEQ_FILE" FM_TEST_FAIL_FLAG="$FAIL_FLAG" \
    FM_FLEET_PUBLISH_SNAPSHOT_CMD="$STUB" \
    FM_FLEET_PUBLISH_MIN_CADENCE=1 \
    FM_FLEET_PUBLISH_TICK_SECS=1 \
    "${FM_TEST_START_ENV[@]}" \
    "$PUBLISH" "$@"
}

artifact_marker() {  # <home>
  jq -r '.marker // ""' "$1/state/fleet-snapshot.json" 2>/dev/null || true
}

wait_for_marker_beyond() {  # <home> <marker> [attempts]
  local home=$1 base=$2 attempts=${3:-900} i=0 got
  while [ "$i" -lt "$attempts" ]; do
    got=$(artifact_marker "$home")
    case "$got" in
      ''|*[!0-9]*) ;;
      *) [ "$got" -gt "$base" ] && return 0 ;;
    esac
    sleep 0.2
    i=$(( i + 1 ))
  done
  return 1
}

run_stub start >/dev/null || fail "the publisher did not start on a configured home"
daemon_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STUB_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$daemon_pid" ] || fail "a started publisher must record its pid"
DAEMON_PIDS+=("$daemon_pid")

wait_for_marker_beyond "$STUB_HOME" 0 \
  || fail "the publisher did not publish a first snapshot"
first=$(artifact_marker "$STUB_HOME")
wait_for_marker_beyond "$STUB_HOME" "$first" \
  || fail "the publisher did not republish on its cadence without being asked"
pass "a detached publisher republishes the snapshot on its own cadence"

# The publisher runs in its own process group and outlives the shell that
# started it: that is what lets the artifact keep advancing with no agent alive.
ppid=$(ps -o ppid= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
[ "$ppid" != "$$" ] \
  || fail "the publisher must not remain a child of the shell that started it"
pgid=$(ps -o pgid= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
[ "$pgid" = "$daemon_pid" ] \
  || fail "the publisher must run in its own process group, got pgid=$pgid"
pass "the publisher is detached from the shell and process group that started it"

# A second start is idempotent rather than a second publisher.
out=$(run_stub start) || fail "a second start must succeed"
case "$out" in
  *"already running"*) ;;
  *) fail "a second start must attach to the running publisher, got: $out" ;;
esac
pass "starting an already-running publisher does not start a second one"

# A crash leaves the singleton lock, the record, and the beacon behind. Coming
# back from exactly that is what the session-start arming exists for, so it is
# proven rather than assumed.
kill -KILL "$daemon_pid" 2>/dev/null || true
attempts=0
while [ "$attempts" -lt 100 ]; do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.1
  attempts=$(( attempts + 1 ))
done
[ -e "$STUB_HOME/state/.fleet-publish-daemon.lock" ] \
  || fail "a crashed publisher must leave its singleton lock behind for this case to mean anything"
out=$(run_stub status)
case "$out" in
  *"daemon=stopped"*) ;;
  *) fail "a crashed publisher must not still read as running, got: $out" ;;
esac
run_stub start >/dev/null || fail "start must recover from a crashed publisher's leftovers"
daemon_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STUB_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$daemon_pid" ] || fail "the recovered publisher recorded no pid"
DAEMON_PIDS+=("$daemon_pid")
kill -0 "$daemon_pid" 2>/dev/null || fail "the recovered publisher is not running"
recovered=$(artifact_marker "$STUB_HOME")
wait_for_marker_beyond "$STUB_HOME" "$recovered" \
  || fail "the recovered publisher did not resume its cadence"
pass "a crashed publisher is recovered by the next start rather than blocking it"

# Stopping acts on the same evidence status reports on, so a recorded pid a
# reboot handed to something else is never the thing that gets signalled.
DECOY_PID=
( exec -a fm-fleet-publish-decoy sleep 120 ) >/dev/null 2>&1 &
DECOY_PID=$!
DAEMON_PIDS+=("$DECOY_PID")
saved_record=$(cat "$STUB_HOME/state/.fleet-publish-daemon")
saved_beat_ref="$TMP_ROOT/beat-ref"
touch -r "$STUB_HOME/state/.fleet-publish-beat" "$saved_beat_ref"
printf 'pid=%s\nstarted=seeded\ncadence=1\n' "$DECOY_PID" \
  > "$STUB_HOME/state/.fleet-publish-daemon"
touch -t 202001010000 "$STUB_HOME/state/.fleet-publish-beat"
if run_stub stop >/dev/null 2>&1; then
  fail "stop must refuse a recorded pid that is not beating"
fi
kill -0 "$DECOY_PID" 2>/dev/null \
  || fail "stop signalled a live process that was not the publisher"
printf '%s\n' "$saved_record" > "$STUB_HOME/state/.fleet-publish-daemon"
touch -r "$saved_beat_ref" "$STUB_HOME/state/.fleet-publish-beat"
kill -KILL "$DECOY_PID" >/dev/null 2>&1 || true
wait "$DECOY_PID" >/dev/null 2>&1 || true
DECOY_PID=
pass "stop refuses a recorded pid that is not beating instead of signalling it"

# A FRESH beacon plus a recycled pid is the dangerous case, and it is not the one
# above: there the beacon was stale, so freshness alone still refused. Here the
# publisher died immediately after a beat and the kernel handed its pid to an
# unrelated process while that beacon is still inside the grace window. A
# liveness check that binds only freshness accepts that process as the publisher,
# which both suppresses recovery (start reports "already running" and publishes
# nothing further) and points stop's SIGTERM at a program that has nothing to do
# with firstmate. Identity must be bound, because a shorter grace window would
# only make this rarer.
DECOY_PID=
( exec -a fm-fleet-publish-bystander sleep 120 ) >/dev/null 2>&1 &
DECOY_PID=$!
DAEMON_PIDS+=("$DECOY_PID")
REUSE_HOME="$TMP_ROOT/reuse-home"
IDENT_HOME="$TMP_ROOT/identity-home"
seed_home "$REUSE_HOME"
printf '30\n' > "$REUSE_HOME/config/fleet-snapshot-cadence"
# The dead publisher's own record and a beacon it wrote moments before dying.
printf 'pid=%s\nproc_start=%s\ntoken=%s\nstarted=seeded\ncadence=30\n' \
  "$DECOY_PID" "$(LC_ALL=C ps -p "$DECOY_PID" -o lstart= | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')" \
  dead-instance-token > "$REUSE_HOME/state/.fleet-publish-daemon"
printf 'dead-instance-token\n' > "$REUSE_HOME/state/.fleet-publish-beat"

out=$(env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REUSE_HOME" "$PUBLISH" status)
case "$out" in
  *"daemon=running"*)
    fail "a recycled pid with a fresh beacon must not be reported as a running publisher: $out"
    ;;
esac

# Recovery must not be suppressed: start has to produce a real publisher.
env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REUSE_HOME" "$PUBLISH" start >/dev/null 2>&1 \
  || fail "start must recover rather than mistake a recycled pid for the publisher"
reuse_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$REUSE_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$reuse_pid" ] || fail "recovery recorded no publisher pid"
DAEMON_PIDS+=("$reuse_pid")
[ "$reuse_pid" != "$DECOY_PID" ] \
  || fail "start adopted the unrelated process instead of starting a publisher"
kill -0 "$reuse_pid" 2>/dev/null || fail "the recovered publisher is not running"

# And the unrelated process must never have been signalled.
kill -0 "$DECOY_PID" 2>/dev/null \
  || fail "an unrelated process holding a recycled pid was signalled"
env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$REUSE_HOME" "$PUBLISH" stop >/dev/null 2>&1 || true
kill -0 "$DECOY_PID" 2>/dev/null \
  || fail "stop signalled the unrelated process holding the recycled pid"
kill -KILL "$DECOY_PID" >/dev/null 2>&1 || true
wait "$DECOY_PID" >/dev/null 2>&1 || true
DECOY_PID=
pass "a recycled pid with a fresh beacon is not mistaken for the publisher"

# The record+beacon liveness check above binds identity, but a recycled pid can
# also be met on a sibling path: as the recorded holder of the daemon's own
# singleton lock. fm_lock_try_acquire (bin/fm-wake-lib.sh) is the shared
# primitive that guards that lock, and it treats the lock as legitimately held
# whenever its recorded pid is merely alive - it has no start-time or cmdline
# binding. Fabricate exactly that: a lock recorded against a live process that
# is not a publisher, backdated well past the lock's own mid-acquire freshness
# window so it reads as a lock a dead daemon left behind, with no daemon record
# at all. Recovery through `start` must not be suppressed by this path any more
# than by the record+beacon path above, and the unrelated process must never be
# touched.
seed_home "$LOCK_HOME"
printf '30\n' > "$LOCK_HOME/config/fleet-snapshot-cadence"

DECOY_PID=
( exec -a fm-fleet-publish-lock-decoy sleep 120 ) >/dev/null 2>&1 &
DECOY_PID=$!
DAEMON_PIDS+=("$DECOY_PID")

LOCKDIR="$LOCK_HOME/state/.fleet-publish-daemon.lock"
OWNERDIR="$LOCKDIR.owner.faketest"
mkdir -p "$OWNERDIR"
printf '%s\n' "$DECOY_PID" > "$OWNERDIR/pid"
ln -s "$OWNERDIR" "$LOCKDIR"
touch -h -t 202001010000 "$LOCKDIR"

env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCK_HOME" "$PUBLISH" start >/dev/null 2>&1 \
  || fail "start must recover a publisher even when the daemon lock is held by an unrelated live process"
lock_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$LOCK_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$lock_pid" ] || fail "recovery through the daemon lock recorded no publisher pid"
DAEMON_PIDS+=("$lock_pid")
[ "$lock_pid" != "$DECOY_PID" ] \
  || fail "start adopted the unrelated process holding the daemon lock instead of starting a publisher"
kill -0 "$lock_pid" 2>/dev/null || fail "the recovered publisher is not running"
kill -0 "$DECOY_PID" 2>/dev/null \
  || fail "an unrelated process holding the daemon lock was signalled"
env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCK_HOME" "$PUBLISH" stop >/dev/null 2>&1 || true
kill -KILL "$DECOY_PID" >/dev/null 2>&1 || true
wait "$DECOY_PID" >/dev/null 2>&1 || true
DECOY_PID=
pass "a daemon lock held by an unrelated live process does not suppress start's recovery"

# The lock-steal guard above proves IDENTITY, not freshness: a live,
# correctly-identified publisher whose beacon has merely gone stale - a laptop
# suspending mid-sleep, a slow snapshot read - is still the legitimate lock
# holder. Stealing its lock would start a second daemon publishing
# concurrently, defeating the very mutual exclusion the lock exists to
# provide. A tick window above GRACE (but under cmd_stop's 10s signal-wait, so
# a SIGTERM sent while the daemon is parked in that tick's sleep still lands
# well inside the timeout) leaves the beacon genuinely stale for a few seconds
# between beats while the daemon stays fully live and responsive - the real
# "running-not-beating" state, not a frozen stand-in for it - so a second
# start neither steals its lock nor spawns a competing daemon.
seed_home "$STALE_HOME"
printf '30\n' > "$STALE_HOME/config/fleet-snapshot-cadence"
STALE_ENV=(FM_FLEET_PUBLISH_GRACE=2 FM_FLEET_PUBLISH_TICK_SECS=6 "${FM_TEST_START_ENV[@]}")

env "${STALE_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STALE_HOME" "$PUBLISH" start >/dev/null 2>&1 \
  || fail "the publisher did not start on the stale-beacon home"
stale_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STALE_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$stale_pid" ] || fail "the stale-beacon publisher recorded no pid"
DAEMON_PIDS+=("$stale_pid")

# Past GRACE=2s but well inside the 6s tick window, so the daemon is still
# genuinely alive and simply has not beaten again yet.
sleep 4

out=$(env FM_FLEET_PUBLISH_GRACE=2 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STALE_HOME" "$PUBLISH" status)
case "$out" in
  *"daemon=running-not-beating"*"beacon="*) ;;
  *) fail "a live publisher with a stale beacon must be reported as running-not-beating with its age, got: $out" ;;
esac
case "$out" in
  *"run: bin/fm-fleet-publish.sh start"*)
    fail "a running-not-beating publisher must not carry the start-recovery hint, got: $out"
    ;;
esac

out=$(env "${STALE_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STALE_HOME" "$PUBLISH" start 2>&1)
start_rc=$?
[ "$start_rc" -ne 0 ] \
  || fail "start must refuse to launch against a running-not-beating publisher"
case "$out" in
  *"could not confirm a running publisher"*)
    fail "start's refusal must name the true reason, not a failure-to-confirm message, got: $out"
    ;;
esac
case "$out" in
  *"already running"*"has not beaten"*) ;;
  *) fail "start's refusal must say a publisher is already running but has not beaten, got: $out" ;;
esac
after_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$STALE_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ "$after_pid" = "$stale_pid" ] \
  || fail "a stale beacon must not cause the daemon lock to be stolen and a second publisher started"
kill -0 "$stale_pid" 2>/dev/null \
  || fail "the original publisher must still be alive after a second start attempt against its stale beacon"

out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$STALE_HOME" "$PUBLISH" stop 2>&1)
stop_rc=$?
[ "$stop_rc" -eq 0 ] \
  || fail "stop must signal and stop a running-not-beating publisher, exiting 0, got exit $stop_rc: $out"
attempts=0
while [ "$attempts" -lt 100 ]; do
  kill -0 "$stale_pid" 2>/dev/null || break
  sleep 0.1
  attempts=$(( attempts + 1 ))
done
kill -0 "$stale_pid" 2>/dev/null \
  && fail "stop reported success but the running-not-beating publisher is still alive"

kill -KILL "$stale_pid" >/dev/null 2>&1 || true
wait "$stale_pid" >/dev/null 2>&1 || true
pass "status, start and stop each handle a live publisher with a stale beacon correctly"

# The identity a publisher records must describe the publisher, and this checks
# that against the kernel rather than against itself. state/<home>/.fleet-publish-daemon
# is this script's own published state record (AGENTS.md section 2 lists it), so
# reading it here asserts a state contract, not implementation text: the process
# start time it publishes must be the start time of the pid it publishes.
#
# The regression this guards is worth naming, because it read as flakiness. The
# daemon recorded its identity with BASHPID expanded inside a command
# substitution, which yields that SUBSHELL's pid rather than the daemon's, so it
# recorded the subshell's start time. The two agree whenever they land in the
# same second and differ when they straddle one, and when they differed the
# daemon could never prove it was itself for its whole life: status read it as
# stopped, start could not confirm it, and stop refused to signal it.
IDENT_HOME="$TMP_ROOT/identity-home"
seed_home "$IDENT_HOME"
printf '30\n' > "$IDENT_HOME/config/fleet-snapshot-cadence"
ident_round=0
while [ "$ident_round" -lt 3 ]; do
  ident_round=$(( ident_round + 1 ))
  run_publish "$IDENT_HOME" start >/dev/null 2>&1 \
    || fail "the publisher did not start on round $ident_round of the identity check"
  ident_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
    "$IDENT_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
  [ -n "$ident_pid" ] || fail "the publisher recorded no pid on round $ident_round"
  DAEMON_PIDS+=("$ident_pid")
  ident_recorded=$(sed -n 's/^proc_start=//p' \
    "$IDENT_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
  ident_live=$(LC_ALL=C ps -p "$ident_pid" -o lstart= 2>/dev/null \
    | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  [ -n "$ident_recorded" ] \
    || fail "the publisher published no process start time on round $ident_round"
  [ "$ident_recorded" = "$ident_live" ] \
    || fail "the publisher's recorded identity describes another process: recorded [$ident_recorded] but pid $ident_pid started [$ident_live]"
  out=$(run_publish "$IDENT_HOME" status)
  case "$out" in
    *"daemon=running"*) ;;
    *) fail "a publisher that is running must read as running, got: $out" ;;
  esac
  run_publish "$IDENT_HOME" stop >/dev/null 2>&1 \
    || fail "a running publisher must be stoppable on round $ident_round"
done
pass "the identity a publisher records describes the publisher itself"



# --- 3. a failed producer leaves the previous snapshot intact ---------------
#
# Degrading to stale is correct. Degrading to absent or truncated is not: the
# consumer's own honesty depends on still being able to say how old this is.

before=$(cat "$STUB_HOME/state/fleet-snapshot.json")
before_marker=$(artifact_marker "$STUB_HOME")
: > "$FAIL_FLAG"
# Let the running publisher take at least two failing turns.
attempts=0
seq_at_flag=$(cat "$SEQ_FILE")
while [ "$attempts" -lt 200 ]; do
  now_seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
  [ "$now_seq" -ge $(( seq_at_flag + 2 )) ] && break
  sleep 0.2
  attempts=$(( attempts + 1 ))
done
[ "$attempts" -lt 200 ] || fail "the publisher never attempted a failing read"

after=$(cat "$STUB_HOME/state/fleet-snapshot.json")
[ "$before" = "$after" ] \
  || fail "a failed snapshot read must leave the published snapshot byte-identical"
[ "$(artifact_marker "$STUB_HOME")" = "$before_marker" ] \
  || fail "a failed snapshot read must not advance the published snapshot"
grep -q 'snapshot read failed with exit 7' "$STUB_HOME/state/.fleet-publish.log" \
  || fail "a failed snapshot read must be recorded with its reason"
# No temporary file may be left behind at, or beside, the artifact.
leftovers=$(find "$STUB_HOME/state" -maxdepth 1 -name '.fleet-snapshot.json.*' 2>/dev/null | wc -l)
[ "$(printf '%s' "$leftovers" | tr -d '[:space:]')" = 0 ] \
  || fail "a failed publish must not leave a temporary publication file behind"
pass "a failed snapshot read leaves the previous published snapshot intact"

# A one-shot publish reports the failure to its caller instead of exiting clean.
if run_stub publish >/dev/null 2>&1; then
  fail "a one-shot publish must exit non-zero when the producer fails"
fi
rm -f "$FAIL_FLAG"
wait_for_marker_beyond "$STUB_HOME" "$before_marker" \
  || fail "the publisher must resume publishing once the producer recovers"
pass "publication resumes on its own once the producer recovers"

# --- the daemon honours a configuration that goes away ----------------------

rm -f "$STUB_HOME/config/fleet-snapshot-cadence"
attempts=0
while [ "$attempts" -lt 300 ]; do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.2
  attempts=$(( attempts + 1 ))
done
kill -0 "$daemon_pid" 2>/dev/null \
  && fail "removing the cadence must stop the running publisher"
[ -s "$STUB_HOME/state/fleet-snapshot.json" ] \
  || fail "stopping the publisher must leave the last published snapshot in place"
pass "removing the cadence stops the publisher and leaves the snapshot in place"

# --- a beat that cannot write is a recorded failure, not a silent success ----
#
# beat() must report failure honestly rather than claim success when nothing
# was written: that lie is the concrete trigger that let a genuinely alive
# publisher look identical to a dead one downstream. Make the state directory
# unwritable so beat() cannot create its temporary beacon file, and confirm the
# daemon records the failure once - not once per tick - without terminating.

seed_home "$BEAT_HOME"
printf '3\n' > "$BEAT_HOME/config/fleet-snapshot-cadence"
: > "$BEAT_HOME/state/.fleet-publish.log"
BEAT_ENV=(FM_FLEET_PUBLISH_MIN_CADENCE=1 FM_FLEET_PUBLISH_TICK_SECS=1 "${FM_TEST_START_ENV[@]}")

env "${BEAT_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" "$PUBLISH" start >/dev/null 2>&1 \
  || fail "the publisher did not start on the beat-failure home"
beat_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$BEAT_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$beat_pid" ] || fail "the beat-failure publisher recorded no pid"
DAEMON_PIDS+=("$beat_pid")

chmod 555 "$BEAT_HOME/state"
attempts=0
while [ "$attempts" -lt 100 ]; do
  grep -q "beacon could not be written" "$BEAT_HOME/state/.fleet-publish.log" 2>/dev/null && break
  sleep 0.2
  attempts=$(( attempts + 1 ))
done
chmod 755 "$BEAT_HOME/state"
[ "$attempts" -lt 100 ] \
  || fail "an unwritable state directory must be recorded as a beat failure rather than presenting as healthy"
kill -0 "$beat_pid" 2>/dev/null \
  || fail "a beat failure must not terminate the publisher"
occurrences=$(grep -c "beacon could not be written" "$BEAT_HOME/state/.fleet-publish.log")
[ "$occurrences" -eq 1 ] \
  || fail "a sustained beat failure must be logged once, not once per tick, got $occurrences occurrences"

env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BEAT_HOME" "$PUBLISH" stop >/dev/null 2>&1 || true
kill -KILL "$beat_pid" >/dev/null 2>&1 || true
wait "$beat_pid" >/dev/null 2>&1 || true
pass "an unwritable state directory is recorded as a beat failure rather than presenting as healthy"

# --- 4. atomicity -----------------------------------------------------------
#
# A consumer that watches the file must never observe a half-written document.
# A slow producer emitting a large payload makes the write window wide enough to
# catch, and a reader loop asserts every observation is a whole document.

ATOMIC_HOME="$TMP_ROOT/atomic-home"
seed_home "$ATOMIC_HOME"
printf '300\n' > "$ATOMIC_HOME/config/fleet-snapshot-cadence"

SLOW_STUB="$TMP_ROOT/slow-snapshot.sh"
cat > "$SLOW_STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
filler=$(printf 'x%.0s' $(seq 1 200))
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:01:00Z",'
printf '"fm_home":"%s","roots":{},"backlog":{},"marker":2,"tasks":[' "$FM_HOME"
i=0
while [ "$i" -lt 400 ]; do
  [ "$i" -eq 0 ] || printf ','
  printf '{"id":"task-%s","filler":"%s"}' "$i" "$filler"
  i=$(( i + 1 ))
  case $(( i % 40 )) in 0) sleep 0.2 ;; esac
done
printf ']}\n'
SH
chmod +x "$SLOW_STUB"

# Seed a complete previous document, so "the previous whole one" is a real
# alternative a reader can legitimately observe.
FAST_STUB="$TMP_ROOT/fast-snapshot.sh"
cat > "$FAST_STUB" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 64
printf '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-01T00:00:01Z","fm_home":"%s","roots":{},"backlog":{},"tasks":[],"marker":1}\n' "$FM_HOME"
SH
chmod +x "$FAST_STUB"

FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ATOMIC_HOME" \
  FM_FLEET_PUBLISH_SNAPSHOT_CMD="$FAST_STUB" "$PUBLISH" publish >/dev/null \
  || fail "seeding the previous published snapshot failed"

# The reader is bounded by the publish itself, not by a wall clock, so the
# window it samples is exactly the window a torn write could appear in.
READER_VERDICT="$TMP_ROOT/reader-verdict"
READER_TEMPS="$TMP_ROOT/reader-temps"
: > "$READER_VERDICT"
: > "$READER_TEMPS"

FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ATOMIC_HOME" \
  FM_FLEET_PUBLISH_SNAPSHOT_CMD="$SLOW_STUB" \
  FM_FLEET_PUBLISH_TIMEOUT=120 "$PUBLISH" publish >/dev/null 2>&1 &
PUBLISH_PID=$!
DAEMON_PIDS+=("$PUBLISH_PID")

sample_artifact() {
  local marker
  marker=$(jq -r '.marker // "PARSE_FAILED"' \
    "$ATOMIC_HOME/state/fleet-snapshot.json" 2>/dev/null) || marker=PARSE_FAILED
  [ -n "$marker" ] || marker=PARSE_FAILED
  printf '%s\n' "$marker" >> "$READER_VERDICT"
  # A visible (non dot-prefixed) temporary beside the artifact would be a
  # directory-change event a watching consumer could try to read.
  find "$ATOMIC_HOME/state" -maxdepth 1 -name 'fleet-snapshot.json.*' 2>/dev/null \
    >> "$READER_TEMPS"
}

while kill -0 "$PUBLISH_PID" 2>/dev/null; do
  sample_artifact
done
wait "$PUBLISH_PID" || fail "the slow atomic publish failed"
sample_artifact

reads=$(grep -c . "$READER_VERDICT" 2>/dev/null || echo 0)
[ "$reads" -ge 5 ] || fail "the atomicity reader observed too few reads ($reads) to prove anything"
if grep -qv '^[12]$' "$READER_VERDICT"; then
  fail "a reader observed something other than a whole previous or next snapshot: $(sort -u "$READER_VERDICT" | tr '\n' ' ')"
fi
grep -q '^1$' "$READER_VERDICT" \
  || fail "the reader never observed the previous whole snapshot during the write"
grep -q '^2$' "$READER_VERDICT" \
  || fail "the reader never observed the next whole snapshot"
[ ! -s "$READER_TEMPS" ] \
  || fail "a visible temporary file appeared beside the published snapshot: $(head -1 "$READER_TEMPS")"
jq -e '.marker == 2 and (.tasks | length) == 400' \
  "$ATOMIC_HOME/state/fleet-snapshot.json" >/dev/null \
  || fail "the completed publish did not replace the artifact with the whole new document"
pass "a publish is atomic: a reader sees the previous whole snapshot or the next one"

# --- session-start arming ---------------------------------------------------
#
# The publisher has to come back on its own after a reboot or a crash, so a
# locked session boundary arms it. An opted-out home must pay nothing there, and
# an unusable configuration must reach the agent as an actionable line rather
# than a home that quietly stopped publishing.

seed_home "$BOOT_HOME"
run_bootstrap() {
  env "${FM_TEST_START_ENV[@]}" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BOOT_HOME" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" check 2>&1
}

out=$(run_bootstrap)
case "$out" in
  *FLEET_PUBLISH*) fail "session start must say nothing about publishing on a home that did not opt in" ;;
esac
[ ! -e "$BOOT_HOME/state/.fleet-publish-daemon" ] \
  || fail "session start must not arm a publisher on a home that did not opt in"
pass "session start leaves a home that did not opt in alone"

printf 'never\n' > "$BOOT_HOME/config/fleet-snapshot-cadence"
out=$(run_bootstrap)
case "$out" in
  *"FLEET_PUBLISH: config/fleet-snapshot-cadence must be one positive whole number of seconds"*) ;;
  *) fail "session start must report an unusable cadence as an actionable line, got: $out" ;;
esac
case "$out" in
  *"FLEET_PUBLISH: fm-fleet-publish:"*) fail "the reported line must carry one prefix, not two" ;;
esac
pass "session start reports an unusable cadence instead of publishing nothing quietly"

printf '300\n' > "$BOOT_HOME/config/fleet-snapshot-cadence"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$BOOT_HOME" FM_BOOTSTRAP_NETWORK=skip \
  FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" check >/dev/null 2>&1
[ ! -e "$BOOT_HOME/state/.fleet-publish-daemon" ] \
  || fail "a read-only session start must not arm a publisher"
pass "a read-only session start arms no publisher"

out=$(run_bootstrap)
case "$out" in
  *FLEET_PUBLISH*) fail "session start must arm the publisher silently when it works, got: $out" ;;
esac
boot_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' \
  "$BOOT_HOME/state/.fleet-publish-daemon" 2>/dev/null | head -1)
[ -n "$boot_pid" ] || fail "session start must arm a publisher on an opted-in home"
DAEMON_PIDS+=("$boot_pid")
kill -0 "$boot_pid" 2>/dev/null || fail "the publisher session start armed is not running"
pass "session start arms the publisher on an opted-in home"

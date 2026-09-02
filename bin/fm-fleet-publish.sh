#!/usr/bin/env bash
# fm-fleet-publish.sh - publish this home's fleet snapshot to a stable path on a
# cadence, for a consumer that WATCHES A FILE rather than running a command.
#
# WHY THIS EXISTS. bin/fm-fleet-snapshot.sh is invoked on demand only, by
# bin/fm-fleet-view.sh, bin/fm-bearings-snapshot.sh, and
# bin/fm-home-summary-refresh.sh. That is correct for a command and wrong for a
# reader that cannot run one: a surface that reads bytes and watches directories
# renders whatever the last manual run left behind, and can only badge its own
# age. This script is that missing publisher. It adds nothing to the snapshot and
# changes nothing about it: the published artifact is the exact
# `fm-fleet-snapshot.sh --json` document, schema `fm-fleet-snapshot.v1`
# unchanged, so a consumer that pins the schema id keeps rendering.
#
# WHY NOT AN EXISTING MECHANISM. This repository already supervises recurring
# background work four ways, and none of them fits:
#   - Watcher check shims (state/<id>.check.sh, armed the way
#     bin/fm-tool-update-check.sh arms its own) run on the watcher's poll. The
#     watcher is armed BY an agent and its cycle ends with the agent, so a home
#     with no live session publishes nothing. That is also the coupling the
#     captain rejected on 2026-09-01 when this work was scoped: a stopped
#     supervision cycle would silently freeze the surface, which is the exact
#     state the finding observed.
#   - Process-to-event sources (bin/fm-procevent.sh) are wake transport. They
#     capture a result so firstmate can read it on its next turn, and they are
#     polled by the same watcher, so they inherit the same lifetime.
#   - The away-mode sub-supervisor (bin/fm-supervise-daemon.sh) is gated on
#     state/.afk by contract and owns supervision only while the captain is away.
#   - There is no launchd, cron, or systemd unit anywhere in bin/. Firstmate does
#     not install host-level timers, and adding one for a snapshot would put a
#     unit outside the operational home that no `fm-` command owns.
# What DOES fit is the detach pattern bin/fm-startup-network.sh already proved
# for work that must outlive the shell that launched it: immunity to the
# launching shell's HUP, its own process group, stdio detached. Both scripts get
# the first property by ignoring SIGHUP in a subshell that then execs, rather
# than from nohup, which exits 127 in the sandbox these launchers are tested in;
# a direct trap keeps each launcher testable there rather than hidden behind a
# shim. This script reuses the pattern and adds only the loop.
# Its write path is bin/fm-home-summary-refresh.sh's publication contract
# (serialize, validate, rename), applied to the canonical snapshot.
#
# CONFIGURATION. config/fleet-snapshot-cadence, one positive decimal integer of
# seconds (at most 10 digits, so the comparison below can never overflow) followed
# by exactly one newline, in a regular single-linked file under a non-symlinked
# config/. ABSENT MEANS DISABLED: no daemon, no artifact, no
# cost. Malformed is refused as malformed and never silently treated as a
# default, because a home that believes it is publishing and is not is the
# failure this whole mechanism exists to remove. `status` always says which of
# the three states this home is in. docs/configuration.md owns the operator-facing
# schema; this header owns the mechanics.
#
# WHAT A CADENCE COSTS. A snapshot read is real work: it forks per task for
# bin/fm-crew-state.sh, reads every state/<id>.meta and status tail, does one
# endpoint presence check per task, and samples every registered secondmate home.
# It makes no network call. Cost therefore scales with tasks plus secondmate
# homes, not with fleet activity. Measured 2026-09-01 on a primary home with 6
# task records and no secondmates: 2.9s wall, 0.4s CPU, 49KB of JSON. A 300s
# cadence is that home's default and spends about 1% of one core; 60s would
# spend 5% continuously to shave four minutes off a staleness badge, which is
# not a trade worth defaulting to. Below FM_FLEET_PUBLISH_MIN_CADENCE (30s) the
# duty cycle stops being background on any fleet large enough to want this, so a
# smaller configured value is refused rather than accepted and degraded.
#
# ATOMICITY AND FAILURE. A publish writes a dot-prefixed temporary file in the
# state directory, validates it, then renames it over the artifact. A consumer
# that watches the directory never sees a partial document and never sees the
# temporary name, because the rename is the only appearance. A snapshot that
# fails, times out, or returns a document that does not validate leaves the
# previous artifact byte-identical: degrading to stale is correct, and the
# consumer can still say how old the picture is from the artifact's own
# `generated` field. Failures append to a bounded state/.fleet-publish.log.
#
# Usage:
#   fm-fleet-publish.sh status
#          Print this home's publication state and exit 0. Names which of
#          disabled / misconfigured / enabled applies, whether the daemon is
#          running, and the published artifact's own age.
#   fm-fleet-publish.sh publish
#          Publish once, now, in the foreground. This is an explicit operator
#          action and works whether or not a cadence is configured; a cadence is
#          what a home pays for automatically, a hand-run publish is not.
#          Exits non-zero with the reason when the publish failed.
#   fm-fleet-publish.sh start
#          Idempotently start this home's detached publisher. Refuses when no
#          valid cadence is configured. An already-running daemon is left alone.
#          Verifies before reporting: it prints started/attached only after the
#          daemon holds this home's singleton lock with a fresh beacon.
#          A publisher killed outright leaves its singleton lock, record, and
#          beacon behind; the next start steals that dead holder's lock and
#          takes over, which is what makes a reboot or a crash recoverable by an
#          ordinary session start rather than by hand.
#   fm-fleet-publish.sh stop
#          Stop exactly this home's daemon, by the pid recorded in this home's
#          own record. It never matches on a command name, so it can never touch
#          another home's publisher.
#   fm-fleet-publish.sh run
#          The cadence loop itself, in the foreground. This is what `start`
#          detaches; run it directly to watch the loop or to host it under a
#          supervisor of your own.
#
# The loop re-reads the configuration on every tick. A changed cadence takes
# effect without a restart, and removing or breaking the file stops the daemon
# once it still reads that way on a second consecutive look - within about two
# ticks, not one, because a single unreadable moment must not retire a
# publisher the home still wants. That is what makes "absent configuration
# means absent behaviour" true continuously rather than only at start time.
#
# Environment:
#   FM_FLEET_PUBLISH_TIMEOUT       seconds bounding one snapshot read (default 120)
#   FM_FLEET_PUBLISH_MIN_CADENCE   smallest accepted cadence (default 30)
#   FM_FLEET_PUBLISH_TICK_SECS     loop slice, bounds how fast the daemon notices
#                                  a configuration change (default 5)
#   FM_FLEET_PUBLISH_GRACE         beacon freshness allowance for the liveness
#                                  check (default FM_FLEET_PUBLISH_TIMEOUT + 60)
#   FM_FLEET_PUBLISH_START_WAIT    seconds `start` waits to verify one attempt (default 15)
#   FM_FLEET_PUBLISH_START_ATTEMPTS  launch attempts before start gives up (default 3)
#   FM_FLEET_PUBLISH_LOG_MAX_BYTES bounded failure log size (default 65536)
#   FM_FLEET_PUBLISH_SNAPSHOT_CMD  test seam: the snapshot producer to run
#                                  (default bin/fm-fleet-snapshot.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

CADENCE_FILE="$CONFIG/fleet-snapshot-cadence"
ARTIFACT="$STATE/fleet-snapshot.json"
PUBLISH_LOCK="$STATE/.fleet-publish.lock"
DAEMON_LOCK="$STATE/.fleet-publish-daemon.lock"
DAEMON_RECORD="$STATE/.fleet-publish-daemon"
BEACON="$STATE/.fleet-publish-beat"
ERROR_LOG="$STATE/.fleet-publish.log"
LAUNCH_ERR="$STATE/.fleet-publish-launch.err"

PUBLISH_TIMEOUT=${FM_FLEET_PUBLISH_TIMEOUT:-120}
MIN_CADENCE=${FM_FLEET_PUBLISH_MIN_CADENCE:-30}
MAX_CADENCE_DIGITS=10
TICK_SECS=${FM_FLEET_PUBLISH_TICK_SECS:-5}
START_WAIT=${FM_FLEET_PUBLISH_START_WAIT:-15}
START_ATTEMPTS=${FM_FLEET_PUBLISH_START_ATTEMPTS:-3}
LOG_MAX_BYTES=${FM_FLEET_PUBLISH_LOG_MAX_BYTES:-65536}
SNAPSHOT_CMD=${FM_FLEET_PUBLISH_SNAPSHOT_CMD:-$SCRIPT_DIR/fm-fleet-snapshot.sh}

case "$PUBLISH_TIMEOUT" in ''|*[!0-9]*|0) PUBLISH_TIMEOUT=120 ;; esac
case "$MIN_CADENCE" in ''|*[!0-9]*|0) MIN_CADENCE=30 ;; esac
case "$TICK_SECS" in ''|*[!0-9]*|0) TICK_SECS=5 ;; esac
case "$START_WAIT" in ''|*[!0-9]*|0) START_WAIT=15 ;; esac
case "$START_ATTEMPTS" in ''|*[!0-9]*|0) START_ATTEMPTS=3 ;; esac
case "$LOG_MAX_BYTES" in ''|*[!0-9]*|0) LOG_MAX_BYTES=65536 ;; esac
GRACE=${FM_FLEET_PUBLISH_GRACE:-$(( PUBLISH_TIMEOUT + 60 ))}
case "$GRACE" in ''|*[!0-9]*|0) GRACE=$(( PUBLISH_TIMEOUT + 60 )) ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

FLEET_PUBLISH_ERROR=
FLEET_PUBLISH_CADENCE=
FLEET_PUBLISH_TMP=
FLEET_PUBLISH_ERR_TMP=
FLEET_PUBLISH_LOCK_HELD=0
FLEET_PUBLISH_DAEMON_LOCK_HELD=0

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  FLEET_PUBLISH_ERROR=$1
  return 1
}

now_epoch() {
  date +%s 2>/dev/null
}

path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# proc_start_of <pid>: the kernel's start time for that pid, normalized.
# A recycled pid gets a new start time, so this is what separates "the process
# we recorded" from "whatever now holds that number". LC_ALL=C pins lstart's
# date format to be locale-invariant, matching fm-wake-lib.sh's fm_pid_identity:
# the identity is written under one locale and re-read under the machine's
# ambient locale, which would otherwise mismatch on a non-C locale and reject a
# live publisher.
proc_start_of() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# proc_is_publisher <pid>: the live process is running this script.
proc_is_publisher() {
  ps -p "$1" -o args= 2>/dev/null | grep -q 'fm-fleet-publish\.sh'
}

# new_instance_token: identifies one publisher INSTANCE, not one pid. Only a live
# daemon ever writes it into the beacon, so a beacon carrying a different token
# belongs to an instance that is gone.
new_instance_token() {
  local token=
  token=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ -n "$token" ] || token="${BASHPID:-$$}-$(date +%s 2>/dev/null)-${RANDOM:-0}"
  printf '%s\n' "$token"
}

link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# read_cadence: sets FLEET_PUBLISH_CADENCE to the validated cadence.
# Exit 0 configured and valid; 1 absent (disabled); 2 present but unusable, with
# the reason in FLEET_PUBLISH_ERROR. Absent and invalid are deliberately
# different exits: a home that configured a cadence and typed it wrong must not
# be reported as a home that chose not to publish. It reports through globals
# rather than stdout so a caller can never lose the reason to a subshell and
# report an unusable configuration as an unexplained one.
read_cadence() {
  local value links
  FLEET_PUBLISH_ERROR=
  FLEET_PUBLISH_CADENCE=
  if [ -L "$CONFIG" ]; then
    fail "config directory is symlinked: $CONFIG"
    return 2
  fi
  if [ ! -e "$CADENCE_FILE" ] && [ ! -L "$CADENCE_FILE" ]; then
    return 1
  fi
  if [ -L "$CADENCE_FILE" ]; then
    fail "config/fleet-snapshot-cadence is symlinked"
    return 2
  fi
  if [ ! -f "$CADENCE_FILE" ]; then
    fail "config/fleet-snapshot-cadence is not a regular file"
    return 2
  fi
  links=$(link_count "$CADENCE_FILE") || {
    fail "could not inspect config/fleet-snapshot-cadence"
    return 2
  }
  if [ "$links" != 1 ]; then
    fail "config/fleet-snapshot-cadence is hardlinked"
    return 2
  fi
  value=$(<"$CADENCE_FILE") || {
    fail "could not read config/fleet-snapshot-cadence"
    return 2
  }
  case "$value" in
    ''|0|*[!0-9]*|0*)
      fail "config/fleet-snapshot-cadence must be one positive whole number of seconds"
      return 2
      ;;
  esac
  if [ "${#value}" -gt "$MAX_CADENCE_DIGITS" ]; then
    fail "config/fleet-snapshot-cadence is ${#value} digits, more than the ${MAX_CADENCE_DIGITS}-digit maximum a cadence can be"
    return 2
  fi
  if ! printf '%s\n' "$value" | cmp -s "$CADENCE_FILE" -; then
    fail "config/fleet-snapshot-cadence must contain exactly one value followed by one newline"
    return 2
  fi
  if [ "$value" -lt "$MIN_CADENCE" ]; then
    fail "config/fleet-snapshot-cadence is ${value}s, below the ${MIN_CADENCE}s floor a snapshot read can sustain"
    return 2
  fi
  FLEET_PUBLISH_CADENCE=$value
  return 0
}

log_failure() {
  local message=$1 stamp size tmp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || stamp=unknown
  if ! printf '[%s] %s\n' "$stamp" "$message" >> "$ERROR_LOG" 2>/dev/null; then
    printf 'fm-fleet-publish: %s\n' "$message" >&2
    return 0
  fi
  size=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
    tmp="$ERROR_LOG.tmp.${BASHPID:-$$}"
    tail -n 200 "$ERROR_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$ERROR_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
publish_cleanup() {
  [ -z "$FLEET_PUBLISH_TMP" ] || rm -f -- "$FLEET_PUBLISH_TMP" 2>/dev/null || true
  [ -z "$FLEET_PUBLISH_ERR_TMP" ] || rm -f -- "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null || true
  FLEET_PUBLISH_TMP=
  FLEET_PUBLISH_ERR_TMP=
  if [ "$FLEET_PUBLISH_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PUBLISH_LOCK" || true
    FLEET_PUBLISH_LOCK_HELD=0
  fi
}

# publish_once: one complete atomic publication.
# Every failure path returns non-zero with FLEET_PUBLISH_ERROR set and leaves the
# existing artifact untouched. The temporary file is dot-prefixed and lives in
# the state directory so the rename is atomic on that filesystem and a consumer
# watching the directory never observes a name it could try to read.
publish_once() {
  local producer_rc producer_error
  if ! mkdir -p "$STATE" 2>/dev/null; then
    fail "state directory is unavailable: $STATE"
    return 1
  fi
  fm_lock_acquire_wait "$PUBLISH_LOCK"
  FLEET_PUBLISH_LOCK_HELD=1
  FLEET_PUBLISH_TMP=$(umask 077; mktemp "$STATE/.fleet-snapshot.json.XXXXXX") || {
    fail "could not create an atomic publication file in $STATE"
    publish_cleanup
    return 1
  }
  FLEET_PUBLISH_ERR_TMP=$(umask 077; mktemp "$STATE/.fleet-snapshot-error.XXXXXX") || {
    fail "could not create a producer diagnostic file in $STATE"
    publish_cleanup
    return 1
  }

  if fm_run_timed "$PUBLISH_TIMEOUT" env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$SNAPSHOT_CMD" --json \
      > "$FLEET_PUBLISH_TMP" 2> "$FLEET_PUBLISH_ERR_TMP"; then
    producer_rc=0
  else
    producer_rc=$?
  fi
  if [ "$producer_rc" -ne 0 ]; then
    producer_error=$(tail -n 1 "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null \
      | tr '\t\r\n' '   ' | cut -c1-500)
    if [ "$producer_rc" -eq 124 ]; then
      fail "snapshot read exceeded its ${PUBLISH_TIMEOUT}-second deadline; the published snapshot is unchanged"
    elif [ -n "$producer_error" ]; then
      fail "snapshot read failed with exit $producer_rc: $producer_error; the published snapshot is unchanged"
    else
      fail "snapshot read failed with exit $producer_rc; the published snapshot is unchanged"
    fi
    publish_cleanup
    return 1
  fi
  rm -f -- "$FLEET_PUBLISH_ERR_TMP" 2>/dev/null || true
  FLEET_PUBLISH_ERR_TMP=

  if ! jq -e --arg home "$FM_HOME" '
    .schema == "fm-fleet-snapshot.v1"
    and .fm_home == $home
    and (.generated | type) == "string"
    and (.generated | length) > 0
    and (.roots | type) == "object"
    and (.backlog | type) == "object"
    and (.tasks | type) == "array"
  ' "$FLEET_PUBLISH_TMP" >/dev/null 2>&1; then
    fail "snapshot read returned a document that is not a usable fm-fleet-snapshot.v1 for this home; the published snapshot is unchanged"
    publish_cleanup
    return 1
  fi
  if ! chmod 600 "$FLEET_PUBLISH_TMP" 2>/dev/null; then
    fail "could not set the publication file mode"
    publish_cleanup
    return 1
  fi
  if ! mv -f -- "$FLEET_PUBLISH_TMP" "$ARTIFACT" 2>/dev/null; then
    fail "atomic replacement of the published snapshot failed: $ARTIFACT"
    publish_cleanup
    return 1
  fi
  FLEET_PUBLISH_TMP=
  publish_cleanup
  return 0
}

artifact_generated() {
  [ -f "$ARTIFACT" ] && [ -r "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ] || return 1
  LC_ALL=C sed -n 's/.*"generated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ARTIFACT" 2>/dev/null | head -1
}

record_pid() {
  record_field pid
}

record_field() {  # <name>
  [ -f "$DAEMON_RECORD" ] && [ ! -L "$DAEMON_RECORD" ] || return 1
  LC_ALL=C sed -n "s/^$1=\\(.*\\)$/\\1/p" "$DAEMON_RECORD" 2>/dev/null | head -1
}

# daemon_identity: 0 when DAEMON_RECORD's pid is genuinely THIS home's publisher.
# This answers identity alone - "is the recorded holder who it claims to be" -
# and says nothing about whether it is still making progress. Four facts must
# agree, and each rules out a different impostor:
#   1. the recorded pid is alive                  - it exists at all;
#   2. its kernel start time equals the recorded  - it is the SAME process, not a
#      one, so a recycled pid cannot pass           later tenant of that number;
#   3. it is running this script                  - it is a publisher, not an
#                                                   unrelated program;
#   4. the beacon carries this instance's token   - it is THIS publisher, and the
#                                                   beacon was written by a live
#                                                   instance rather than left
#                                                   behind by a dead one.
# daemon_state below adds the freshness gate on top of this to classify
# progress as well as identity; cmd_run's lock-steal guard calls this directly
# instead of daemon_state because a steal decision must not depend on how
# recently the genuine publisher happened to beat. Every other caller goes
# through daemon_state, so freshness stays a single owner rather than a
# divergent second copy of these four facts.
daemon_identity() {
  local pid recorded_token recorded_start live_start beacon_token
  pid=$(record_pid) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  recorded_token=$(record_field token) || return 1
  recorded_start=$(record_field proc_start) || return 1
  [ -n "$recorded_token" ] && [ -n "$recorded_start" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  live_start=$(proc_start_of "$pid")
  [ -n "$live_start" ] && [ "$live_start" = "$recorded_start" ] || return 1
  proc_is_publisher "$pid" || return 1
  beacon_token=$(head -n 1 "$BEACON" 2>/dev/null || true)
  [ "$beacon_token" = "$recorded_token" ] || return 1
  printf '%s\n' "$pid"
  return 0
}

# daemon_state: classifies the recorded publisher into exactly one of three
# states and prints "<pid>\t<age>" on stdout whenever a pid is known (both
# running states; stdout is empty when stopped). The return code carries the
# state:
#   0  running             - identity proven, beacon fresh.
#   1  stopped             - no record, or identity unprovable. Recoverable.
#   2  running-not-beating - identity proven, beacon stale (e.g. the host
#                            suspended past GRACE while the daemon slept).
# status, start and stop all read this one function rather than each branching
# on identity and freshness themselves, so the operator surface cannot drift
# out of step with what the lock-steal guard in cmd_run already treats as
# proof of identity. It is built on daemon_identity for identity; freshness is
# answered here and nowhere else, so it stays a single owner rather than a
# divergent second copy of that arithmetic.
#
# Liveness must bind IDENTITY, not merely freshness. A pid plus a fresh beacon is
# not proof: if the publisher dies just after a beat and the kernel hands its pid
# to an unrelated process while that beacon is still inside the grace window, a
# freshness-only check calls that unrelated process the publisher. Shortening
# the grace window only makes that race rarer; it stays wrong, so the window is
# not the fix. daemon_identity above proves identity first; only then does this
# function answer freshness, which is progress rather than identity. A record
# written before identity binding existed lacks the token and start time; it is
# treated as unprovable and therefore stopped, so recovery runs. That direction
# is deliberate: an extra start attempt is harmless because the singleton lock
# admits one daemon, while a false "already running" loses publication silently.
daemon_state() {
  local pid mtime now age
  pid=$(daemon_identity) || return 1
  mtime=$(path_mtime "$BEACON") || { printf '%s\t\n' "$pid"; return 2; }
  case "$mtime" in ''|*[!0-9]*) printf '%s\t\n' "$pid"; return 2 ;; esac
  now=$(now_epoch) || { printf '%s\t\n' "$pid"; return 2; }
  case "$now" in ''|*[!0-9]*) printf '%s\t\n' "$pid"; return 2 ;; esac
  age=$(( now - mtime ))
  printf '%s\t%s\n' "$pid" "$age"
  [ "$age" -le "$GRACE" ] || return 2
  return 0
}

cmd_status() {
  local cadence rc state_out state_rc pid age generated now stamp artifact_age
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  case "$rc" in
    0) ;;
    1) echo "publisher: disabled (config/fleet-snapshot-cadence is absent, so this home publishes nothing on its own)" ;;
    *) echo "publisher: misconfigured ($FLEET_PUBLISH_ERROR)" ;;
  esac
  if [ "$rc" -eq 0 ]; then
    state_out=$(daemon_state); state_rc=$?
    case "$state_rc" in
      0)
        pid=${state_out%%$'\t'*}
        age=${state_out#*$'\t'}
        echo "publisher: enabled cadence=${cadence}s daemon=running pid=$pid beacon=${age}s"
        ;;
      2)
        pid=${state_out%%$'\t'*}
        age=${state_out#*$'\t'}
        echo "publisher: enabled cadence=${cadence}s daemon=running-not-beating pid=$pid beacon=${age}s (identified but not making progress; run: bin/fm-fleet-publish.sh stop)"
        ;;
      *)
        echo "publisher: enabled cadence=${cadence}s daemon=stopped (run: bin/fm-fleet-publish.sh start)"
        ;;
    esac
  fi
  if generated=$(artifact_generated) && [ -n "$generated" ]; then
    artifact_age=unknown
    stamp=$(path_mtime "$ARTIFACT") || stamp=
    now=$(now_epoch) || now=
    if [ -n "$stamp" ] && [ -n "$now" ]; then
      artifact_age="$(( now - stamp ))s"
    fi
    echo "snapshot: $ARTIFACT generated=$generated published=${artifact_age} ago"
  else
    echo "snapshot: $ARTIFACT has not been published"
  fi
  return 0
}

cmd_publish() {
  trap publish_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if publish_once; then
    echo "publisher: published $ARTIFACT"
    return 0
  fi
  log_failure "$FLEET_PUBLISH_ERROR"
  printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
  return 1
}

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps in cmd_run.
daemon_cleanup() {
  publish_cleanup
  if [ "$FLEET_PUBLISH_DAEMON_LOCK_HELD" -eq 1 ]; then
    rm -f -- "$DAEMON_RECORD" 2>/dev/null || true
    fm_lock_release "$DAEMON_LOCK" || true
    FLEET_PUBLISH_DAEMON_LOCK_HELD=0
  fi
}

# The beacon carries the live instance's token, so it is evidence of WHO is
# beating and not only of WHEN. A dead instance's beacon can still be recent, but
# it can never carry a later instance's token.
FLEET_PUBLISH_TOKEN=

# The beat is published by rename, never by truncating the beacon in place.
# A plain redirect empties the file before it refills it, and a reader landing in
# that window sees no token and concludes the publisher is gone - which would
# make a healthy publisher intermittently unrecoverable and intermittently
# unstoppable. The rename also carries the mtime the freshness check reads.
# Failure is reported honestly (non-zero) rather than swallowed: the beacon is
# the one signal daemon_state trusts to mean "making progress", so a heartbeat
# that claims success when it did not write anything would let an unwritable or
# full state directory present as a healthy publisher whose beacon merely ages.
beat() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fleet-publish-beat.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$FLEET_PUBLISH_TOKEN" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$BEACON" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

# beat_or_log: calls beat and logs the failure once when it starts, not on every
# tick while it persists - a sustained outage should be one diagnosable line in
# state/.fleet-publish.log, not a flood, and must never stop the publisher: a
# transient write failure retiring the daemon would repeat the retire-on-one-
# bad-look mistake already corrected for the cadence file.
FLEET_PUBLISH_BEAT_FAILING=0
beat_or_log() {
  if beat; then
    FLEET_PUBLISH_BEAT_FAILING=0
    return 0
  fi
  if [ "$FLEET_PUBLISH_BEAT_FAILING" -eq 0 ]; then
    FLEET_PUBLISH_BEAT_FAILING=1
    log_failure "the beacon could not be written; the publisher is running but $BEACON is not being refreshed (state directory unwritable or full)"
  fi
  return 1
}

cmd_run() {
  local cadence rc slept slice record_tmp config_failures=0 daemon_pid daemon_proc_start
  local holder_pid holder_proven
  if ! mkdir -p "$STATE" 2>/dev/null; then
    printf 'fm-fleet-publish: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  fi
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ]; then
      printf 'fm-fleet-publish: no cadence is configured, so there is nothing to publish\n' >&2
    else
      printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
    fi
    return 1
  fi
  if ! fm_lock_try_acquire "$DAEMON_LOCK"; then
    # PUBLISHER-LOCAL IDENTITY GUARD. fm_lock_try_acquire (bin/fm-wake-lib.sh) is
    # the shared singleton-lock primitive roughly twenty scripts rely on, and it
    # treats a lock as legitimately held whenever the recorded pid is merely
    # alive (fm_pid_alive) - it has no start-time or cmdline binding. A daemon
    # killed right after the kernel recycles its pid to an unrelated live
    # process therefore still blocks recovery here even though daemon_identity
    # (which DOES bind identity) correctly reports no publisher running. This
    # guard closes that gap for THIS home's daemon lock only, by re-proving the
    # lock's recorded holder with daemon_identity before treating a failed
    # acquire as proof a real publisher is up. Fixing fm_pid_alive/
    # fm_lock_try_acquire itself is a separate task with a different blast
    # radius (it also gates the watcher and every other home in the fleet) and
    # is filed on its own; do not delete this guard as redundant when that
    # lands, and do not assume it protects more than this one lock.
    # This proves IDENTITY ONLY, deliberately not daemon_state's freshness gate:
    # a live, correctly-identified publisher whose beacon has merely gone stale
    # (a laptop suspending mid-sleep, a slow snapshot read) is still the
    # legitimate lock holder, and stealing its lock would start a second daemon
    # publishing concurrently - exactly the mutual exclusion this lock exists to
    # provide. Only an impostor that cannot prove identity at all is condemned.
    # A lock younger than FM_LOCK_STALE_AFTER is never condemned either, even
    # when identity is unprovable: a publisher that just won the race has not
    # yet had time to write its own record, and stealing that lock mid-startup
    # would break the same mutual exclusion.
    holder_proven=0
    if holder_pid=$(daemon_identity) && [ "$holder_pid" = "$FM_LOCK_HELD_PID" ]; then
      holder_proven=1
    fi
    if [ "$holder_proven" -eq 1 ] \
      || [ "$(fm_path_age "$DAEMON_LOCK")" -lt "$FM_LOCK_STALE_AFTER" ] \
      || { fm_lock_remove_path "$DAEMON_LOCK" 2>/dev/null; ! fm_lock_try_acquire "$DAEMON_LOCK"; }; then
      printf 'fm-fleet-publish: this home already has a publisher running\n' >&2
      return 3
    fi
  fi
  FLEET_PUBLISH_DAEMON_LOCK_HELD=1
  trap daemon_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Identity is recorded BEFORE the first beat, so a reader never sees a beacon
  # it cannot attribute to a recorded instance.
  FLEET_PUBLISH_TOKEN=$(new_instance_token)
  # Published by rename for the same reason the beacon is: a reader that catches
  # a truncate-then-write half-finished sees a record with no token and concludes
  # the publisher is not provable, which would make a healthy daemon read as dead.
  # BASHPID is snapshotted into an ordinary variable FIRST, and deliberately not
  # written inline below. BASHPID re-evaluates in every subshell, so reading it
  # inside a command substitution yields that SUBSHELL's pid, not the daemon's -
  # which recorded the subshell's start time as the daemon's identity. The two
  # agree whenever they fall in the same second and disagree when they straddle a
  # boundary, so the daemon was intermittently unable to prove it was itself:
  # status read it as stopped, start could not confirm it, and stop refused to
  # signal it, for the whole life of that instance.
  daemon_pid=${BASHPID:-$$}
  daemon_proc_start=$(proc_start_of "$daemon_pid")
  record_tmp=$(umask 077; mktemp "$STATE/.fleet-publish-daemon.XXXXXX" 2>/dev/null) || record_tmp=
  if [ -n "$record_tmp" ] \
    && printf 'pid=%s\nproc_start=%s\ntoken=%s\nstarted=%s\ncadence=%s\n' \
      "$daemon_pid" "$daemon_proc_start" "$FLEET_PUBLISH_TOKEN" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$cadence" > "$record_tmp" 2>/dev/null
  then
    mv -f -- "$record_tmp" "$DAEMON_RECORD" 2>/dev/null || rm -f -- "$record_tmp" 2>/dev/null || true
  else
    [ -z "$record_tmp" ] || rm -f -- "$record_tmp" 2>/dev/null || true
  fi
  # The daemon record is now in place, the earliest instant a detached start can
  # confirm this instance, so a launch failure has nothing left to explain past
  # this point. Closing stderr here (rather than leaving it aimed at start's
  # bounded launch-error capture, LAUNCH_ERR) keeps that capture a snapshot of
  # the launch moment instead of a file the daemon could otherwise grow without
  # bound for the rest of its life via log_failure's stderr fallback.
  exec 2>/dev/null
  beat_or_log

  while :; do
    beat_or_log
    if ! publish_once; then
      log_failure "$FLEET_PUBLISH_ERROR"
    fi
    beat_or_log
    # Sleep the cadence in slices so the configuration is re-read every tick
    # instead of once per cadence: a changed cadence takes effect within one
    # tick, and a removed or unusable one stops the daemon within about two
    # ticks (see below). Re-reading here, not only at startup, is what keeps
    # "absent configuration means absent behaviour" true for a daemon that is
    # already running.
    slept=0
    while [ "$slept" -lt "$cadence" ]; do
      slice=$TICK_SECS
      [ $(( cadence - slept )) -ge "$slice" ] || slice=$(( cadence - slept ))
      sleep "$slice"
      slept=$(( slept + slice ))
      beat_or_log
      read_cadence; rc=$?
      if [ "$rc" -eq 0 ]; then
        cadence=$FLEET_PUBLISH_CADENCE
        config_failures=0
      else
        # One unreadable moment is not a decision. A loaded or momentarily
        # unavailable filesystem must not be able to retire a publisher that the
        # home still wants, so stopping requires the configuration to still be
        # gone or unusable on a second consecutive look. A genuinely removed
        # file reads the same way twice and stops the daemon within about two
        # ticks.
        config_failures=$(( config_failures + 1 ))
        if [ "$config_failures" -ge 2 ]; then
          if [ "$rc" -eq 1 ]; then
            log_failure "cadence configuration was removed; the publisher stopped and left the last published snapshot in place"
          else
            log_failure "cadence configuration became unusable ($FLEET_PUBLISH_ERROR); the publisher stopped and left the last published snapshot in place"
          fi
          return 0
        fi
      fi
    done
  done
}

# start_refuse_stale <pid> <age>: the message cmd_start gives when a publisher
# has proven its own identity but has not beaten in a while. Mutual exclusion
# still holds - a second daemon must not be launched against a home that
# already has one - but the reason must say what actually happened (identified,
# stalled) instead of "could not confirm a running publisher", which describes
# the opposite, and must name the operator's actual next step.
start_refuse_stale() {  # <pid> <age>
  printf 'fm-fleet-publish: a publisher (pid=%s) is already running but has not beaten in %ss; run: bin/fm-fleet-publish.sh stop to end it before starting a new one\n' \
    "$1" "$2" >&2
}

cmd_start() {
  local cadence rc state_out state_rc pid age waited attempt launch_err
  local child_pid=''
  read_cadence; rc=$?
  cadence=$FLEET_PUBLISH_CADENCE
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ]; then
      printf 'fm-fleet-publish: no cadence is configured for this home; write one to %s first\n' \
        "$CADENCE_FILE" >&2
    else
      printf 'fm-fleet-publish: %s\n' "$FLEET_PUBLISH_ERROR" >&2
    fi
    return 1
  fi
  if ! mkdir -p "$STATE" 2>/dev/null; then
    printf 'fm-fleet-publish: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  fi
  state_out=$(daemon_state); state_rc=$?
  pid=${state_out%%$'\t'*}
  age=${state_out#*$'\t'}
  case "$state_rc" in
    0) echo "publisher: already running pid=$pid cadence=${cadence}s"; return 0 ;;
    2) start_refuse_stale "$pid" "$age"; return 1 ;;
  esac

  # Detached the same three properties bin/fm-startup-network.sh detaches its
  # worker with: stdio to /dev/null so no caller's pipe is held open, immunity
  # to the launching shell's HUP so the publisher outlives it (a SIGHUP-
  # ignoring subshell, the same as that script, rather than nohup, which exits
  # 127 in the sandbox these are tested in), and its own process group so a
  # bounded caller's group teardown cannot take the publisher down with it.
  # Together those are what let the artifact keep advancing after the agent that
  # armed it is gone.
  # Launching is retried rather than attempted once. A publisher that is still
  # dying holds the singleton lock for a moment, so a child launched into that
  # window loses the race and exits; giving up there would leave a home that
  # asked for a cadence with no publisher, which is the silent-freeze failure
  # this script exists to prevent. Each attempt re-checks whether some other
  # start won in the meantime, so retrying can never produce a second daemon.
  attempt=0
  while [ "$attempt" -lt "$START_ATTEMPTS" ]; do
    attempt=$(( attempt + 1 ))
    state_out=$(daemon_state); state_rc=$?
    pid=${state_out%%$'\t'*}
    age=${state_out#*$'\t'}
    case "$state_rc" in
      0) echo "publisher: already running pid=$pid cadence=${cadence}s"; return 0 ;;
      2) start_refuse_stale "$pid" "$age"; return 1 ;;
    esac
    launch_publisher
    waited=0
    while [ "$waited" -lt "$START_WAIT" ]; do
      state_out=$(daemon_state); state_rc=$?
      pid=${state_out%%$'\t'*}
      age=${state_out#*$'\t'}
      case "$state_rc" in
        0) echo "publisher: started pid=$pid cadence=${cadence}s"; return 0 ;;
        2) start_refuse_stale "$pid" "$age"; return 1 ;;
      esac
      # A child that has already exited will never become the publisher, so stop
      # waiting out the full window and try again.
      [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null && break
      sleep 1
      waited=$(( waited + 1 ))
    done
  done
  # The launcher's own stderr (a failed exec, a missing interpreter, and the
  # like) is captured in LAUNCH_ERR rather than discarded, so a start that never
  # confirms a publisher can say why instead of only that it could not confirm
  # one.
  launch_err=$(cat "$LAUNCH_ERR" 2>/dev/null)
  if [ -n "$launch_err" ]; then
    printf 'fm-fleet-publish: could not confirm a running publisher after %s attempt(s): %s\n' \
      "$START_ATTEMPTS" "$launch_err" >&2
  else
    printf 'fm-fleet-publish: could not confirm a running publisher after %s attempt(s)\n' \
      "$START_ATTEMPTS" >&2
  fi
  return 1
}

launch_publisher() {  # sets child_pid
  local monitor_was_on
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  : > "$LAUNCH_ERR" 2>/dev/null || true
  (
    trap '' HUP
    exec env \
      FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_FLEET_PUBLISH_SNAPSHOT_CMD="$SNAPSHOT_CMD" \
      FM_FLEET_PUBLISH_TIMEOUT="$PUBLISH_TIMEOUT" \
      FM_FLEET_PUBLISH_MIN_CADENCE="$MIN_CADENCE" \
      FM_FLEET_PUBLISH_TICK_SECS="$TICK_SECS" \
      FM_FLEET_PUBLISH_GRACE="$GRACE" \
      FM_FLEET_PUBLISH_LOG_MAX_BYTES="$LOG_MAX_BYTES" \
      "$SCRIPT_DIR/fm-fleet-publish.sh" run
  ) >/dev/null 2>"$LAUNCH_ERR" </dev/null &
  child_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
}

cmd_stop() {
  local pid waited state_out state_rc
  pid=$(record_pid) || pid=
  if [ -z "$pid" ]; then
    echo "publisher: no publisher is recorded for this home"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f -- "$DAEMON_RECORD" 2>/dev/null || true
    echo "publisher: recorded publisher pid=$pid is already gone"
    return 0
  fi
  # Signal on identity alone (daemon_state's running or running-not-beating),
  # not on freshness too: the four identity facts daemon_identity proves are
  # stronger evidence of ownership than most stop commands hold, and a
  # publisher that is merely not beating is still this home's publisher. A
  # recorded pid that a reboot handed to an unrelated process fails identity
  # and is refused rather than signalled, so recycled pids stay protected.
  state_out=$(daemon_state); state_rc=$?
  if [ "$state_rc" -eq 1 ]; then
    printf 'fm-fleet-publish: recorded publisher pid=%s does not prove its identity, so it was not signalled; inspect it and remove %s if it is not a publisher\n' \
      "$pid" "$DAEMON_RECORD" >&2
    return 1
  fi
  pid=${state_out%%$'\t'*}
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'fm-fleet-publish: publisher pid=%s did not stop within 10s\n' "$pid" >&2
    return 1
  fi
  echo "publisher: stopped pid=$pid"
  return 0
}

case "${1:-}" in
  status) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_status ;;
  publish) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_publish ;;
  run) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_run ;;
  start) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_start ;;
  stop) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_stop ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

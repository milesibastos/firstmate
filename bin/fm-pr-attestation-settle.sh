#!/usr/bin/env bash
# fm-pr-attestation-settle.sh - resolve the pull request body and head commit
# that .github/workflows/no-mistakes-required.yml hands to the
# require-no-mistakes action, read live from the forge at run time instead of
# taken from the frozen webhook event payload.
#
# WHY THIS EXISTS
#
# The gate's verdict is a pure function of two facts that must describe the same
# moment: the PR body's pipeline attestation, and the commit the forge currently
# has as the PR head. A `synchronize` event carries both, but not from the same
# moment: the payload's pull_request.head.sha is the commit that was just
# pushed, while the payload's pull_request.body is frozen as it stood *before*
# that push. The pipeline can only write an attestation naming a commit after
# creating it, so on a head change the payload body is structurally guaranteed
# to still name the previous head. The run then reports a mismatch that was
# already obsolete when it was printed, and GitHub keeps that check run on the
# commit forever: it does not supersede an older run of the same check name with
# a newer one, so the pull request carries a permanent red that no later passing
# run and no amount of waiting clears.
#
# This script removes the frozen half. It reads the body and the head together
# from one live API response, so the pair always describes one instant, and on a
# head change it waits for the pipeline's attestation write to land before that
# instant is sampled.
#
# WHAT IT DOES NOT DO
#
# It renders no verdict. Whether a PR satisfies the gate stays entirely with the
# require-no-mistakes action, which is the single owner of that contract; this
# script only decides *when* to sample the pair the action judges, and hands
# over whatever it read. It never rewrites a body, never substitutes an attested
# commit for the live head, and never reports a bind it did not observe: a
# genuinely stale attestation is handed over still mismatched and still fails.
#
# THE WAIT
#
# Waiting is what separates "the pipeline is still writing" from "this
# attestation is stale", and nothing in the body distinguishes them. The wait is
# armed only for the event that has a body write pending by construction:
#
#   synchronize            the head just moved, so the attestation naming it is
#                          necessarily still to come - wait for it
#   opened/edited/reopened the body itself is what just changed or arrived, so
#                          there is nothing pending - judge it immediately
#
# So a contributor's non-compliant PR still fails within seconds of being opened
# or edited, and only a head change pays for the wait. The default deadline is
# deliberately far wider than the worst observed lag between a pipeline push and
# its body write (827s, against 33s and 83s in the other observed cases): a wait
# that ends too early resurrects the permanent red this exists to remove, while
# one that runs long only delays a verdict that was going to be red anyway.
#
# Waiting does not weaken the assertion: at the deadline the last live pair is
# handed over unchanged and a body that never bound still fails, exactly as
# before. While the wait runs, the check is in progress rather than green,
# which is the honest state of a PR whose current head is not yet attested.
#
# FAIL CLOSED
#
# A read that fails is retried - within the deadline when the wait is armed, and
# a bounded number of times when it is not, since a transient forge error must
# not become the standing red this exists to remove. Only a pull request that
# never read at all refuses.
#
# An empty body or head is refused rather than passed on. verify.py falls back
# to the event payload for either input when it is handed an empty string, so
# emitting one would silently restore the stale payload this script exists to
# remove, and could pass a PR on a body that is no longer there.
#
# Usage:
#   fm-pr-attestation-settle.sh --repo <owner/repo> --pr <number> \
#       [--event <name>] [--deadline-secs <n>] [--interval-secs <n>] \
#       [--output <file>]
#   fm-pr-attestation-settle.sh --help
#
# Options:
#   --repo <owner/repo>   repository holding the pull request (required)
#   --pr <number>         pull request number (required)
#   --event <name>        triggering event name; only "synchronize" arms the
#                         wait (default: no wait)
#   --deadline-secs <n>   longest the wait may run, in seconds (default 1800)
#   --interval-secs <n>   delay between live reads, in seconds (default 15)
#   --output <file>       write "head_sha=" and a heredoc-quoted "body=" in
#                         GITHUB_OUTPUT format to this file (default: stdout
#                         summary only)
#
# Reads the pull request through gh, so GH_TOKEN must be set in CI.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-pr-attestation-settle.sh"

ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '
ATTESTATION_CLOSING=' -->'

REPO=
PR_NUMBER=
EVENT=
DEADLINE_SECS=1800
INTERVAL_SECS=15
OUTPUT=

# Bounded retry for the no-wait path, where no deadline covers a transient forge
# error. Unused while the wait is armed: the deadline governs there.
READ_ATTEMPTS=5
READ_RETRY_SECS=5

usage() {
  sed -n '2,88{s/^# \{0,1\}//;s/^#$//;p;}' "$SELF"
}

die() {
  printf 'fm-pr-attestation-settle.sh: %s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'fm-pr-attestation-settle.sh: %s\n' "$1" >&2
  exit 2
}

require_value() {  # <flag> <count>
  [ "$2" -ge 2 ] || usage_error "$1 requires a value"
}

require_number() {  # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) usage_error "$1 requires a whole number of seconds (got '$2')" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      require_value --repo "$#"
      REPO=$2
      shift 2
      ;;
    --pr)
      require_value --pr "$#"
      PR_NUMBER=$2
      shift 2
      ;;
    --event)
      require_value --event "$#"
      EVENT=$2
      shift 2
      ;;
    --deadline-secs)
      require_value --deadline-secs "$#"
      require_number --deadline-secs "$2"
      DEADLINE_SECS=$2
      shift 2
      ;;
    --interval-secs)
      require_value --interval-secs "$#"
      require_number --interval-secs "$2"
      INTERVAL_SECS=$2
      shift 2
      ;;
    --output)
      require_value --output "$#"
      OUTPUT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument '$1'"
      ;;
  esac
done

[ -n "$REPO" ] || usage_error "--repo is required"
[ -n "$PR_NUMBER" ] || usage_error "--pr is required"
case "$PR_NUMBER" in
  ''|*[!0-9]*) usage_error "--pr requires a pull request number (got '$PR_NUMBER')" ;;
esac
command -v gh >/dev/null 2>&1 || die "gh not found; cannot read the pull request live."

# A random token, used both to frame the API response and to quote the body into
# GITHUB_OUTPUT. Random rather than fixed so no pull request body can terminate
# either framing early and inject a forged value.
random_token() {  # <prefix>
  local hex=
  if [ -r /dev/urandom ]; then
    hex=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | dd bs=1 count=32 2>/dev/null || true)
  fi
  if [ "${#hex}" -lt 32 ]; then
    hex=$(printf '%s%s%s' "$$" "${RANDOM:-0}" "$(date +%s 2>/dev/null || printf '0')")
  fi
  printf '%s_%s\n' "$1" "$hex"
}

# The commit the body's attestation claims to describe, or empty when the body
# carries no parseable v1 attestation.
#
# This reads the upstream attestation format only to decide whether to keep
# waiting; it is deliberately not a second implementation of the gate. An
# attestation this cannot parse is treated as "not bound yet", which waits and
# then hands the body over for the action to judge - never as a pass.
attested_head() {  # <body>
  local body=$1 segment
  case "$body" in
    *"$ATTESTATION_PREFIX"*) ;;
    *) return 0 ;;
  esac
  segment=${body#*"$ATTESTATION_PREFIX"}
  case "$segment" in
    *"$ATTESTATION_CLOSING"*) segment=${segment%%"$ATTESTATION_CLOSING"*} ;;
    *) return 0 ;;
  esac
  printf '%s' "$segment" \
    | grep -o '"head_sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]\{7,64\}"' \
    | head -n 1 \
    | grep -o '[0-9a-fA-F]\{7,64\}' \
    | head -n 1
}

PR_HEAD_VALUE=
PR_BODY_VALUE=

# One live read: the head and the body come back in a single response, so the
# pair always describes one instant. Splitting them across two calls would
# reintroduce exactly the skew this script exists to remove.
#
# stdout and stderr are captured separately: gh's stderr is never parsed as
# data, only surfaced on failure, so a warning ahead of an otherwise-successful
# response can never be mistaken for the head. PR_HEAD_VALUE/PR_BODY_VALUE are
# only assigned once the whole shape has validated, so a read this function
# rejects can never mutate either global - the caller's retry loop always sees
# the last fully-validated pair, never a head from one read paired with a body
# from another.
read_pr() {
  local marker raw rest err_file parsed_head parsed_body
  marker=$(random_token FMPR)
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-pr-attestation-settle.XXXXXX") || {
    printf 'live read failed: could not allocate a temp file for stderr\n' >&2
    return 1
  }
  if ! raw=$(gh api "repos/$REPO/pulls/$PR_NUMBER" \
    --jq ".head.sha, \"$marker\", (.body // \"\")" 2>"$err_file"); then
    printf 'live read failed: %s\n' "$(cat "$err_file")" >&2
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  case "$raw" in
    *"$marker"*) ;;
    *)
      printf 'live read returned an unrecognised shape\n' >&2
      return 1
      ;;
  esac
  parsed_head=${raw%%$'\n'*}
  rest=${raw#*$'\n'}
  case "$rest" in
    "$marker") parsed_body='' ;;
    "$marker"$'\n'*) parsed_body=${rest#"$marker"$'\n'} ;;
    *)
      printf 'live read returned an unrecognised shape\n' >&2
      return 1
      ;;
  esac
  PR_HEAD_VALUE=$parsed_head
  PR_BODY_VALUE=$parsed_body
  return 0
}

wait_armed=0
[ "$EVENT" != "synchronize" ] || wait_armed=1

now_secs() {
  date +%s
}

started=$(now_secs)
deadline=$((started + DEADLINE_SECS))
read_ok=0
bound=0
attempts=0

while :; do
  attempts=$((attempts + 1))
  if read_pr; then
    read_ok=1
    attested=$(attested_head "$PR_BODY_VALUE")
    if [ -n "$attested" ] && [ -n "$PR_HEAD_VALUE" ] && [ "$attested" = "$PR_HEAD_VALUE" ]; then
      bound=1
      break
    fi
    # A read that succeeded but did not bind only justifies more time when a
    # body write is actually pending.
    [ "$wait_armed" -eq 1 ] || break
    [ "$(now_secs)" -lt "$deadline" ] || break
    sleep "$INTERVAL_SECS"
    continue
  fi
  # A failed read is not a verdict about the pull request. With the wait armed
  # the deadline already covers the retry; without it there is no deadline to
  # lean on, so retry a bounded number of times rather than turning a transient
  # forge error into exactly the standing red this script exists to remove.
  if [ "$wait_armed" -eq 1 ]; then
    [ "$(now_secs)" -lt "$deadline" ] || break
    sleep "$INTERVAL_SECS"
  else
    [ "$attempts" -lt "$READ_ATTEMPTS" ] || break
    sleep "$READ_RETRY_SECS"
  fi
done

elapsed=$(($(now_secs) - started))

# A read that never succeeded leaves nothing live to judge. Refuse rather than
# fall through to the payload the caller is trying to stop trusting.
[ "$read_ok" -eq 1 ] || die "could not read $REPO#$PR_NUMBER after ${attempts} attempt(s) over ${elapsed}s."

# verify.py falls back to the event payload for an empty input, so emitting one
# would quietly restore the stale body. Refuse instead.
[ -n "$PR_HEAD_VALUE" ] || die "$REPO#$PR_NUMBER reported no head commit; refusing to fall back to the event payload."
[ -n "$PR_BODY_VALUE" ] || die "$REPO#$PR_NUMBER has an empty body, so it carries no pipeline attestation; refusing to fall back to the event payload."

if [ "$bound" -eq 1 ]; then
  printf 'Live PR body attestation binds to head %s (after %ss, %s read(s)).\n' \
    "$PR_HEAD_VALUE" "$elapsed" "$attempts"
elif [ "$wait_armed" -eq 1 ]; then
  printf 'Live PR body attestation did not bind to head %s within %ss (%s read(s)); handing the last live pair to the gate.\n' \
    "$PR_HEAD_VALUE" "$elapsed" "$attempts"
else
  printf 'Read live PR body and head %s without waiting (event: %s).\n' \
    "$PR_HEAD_VALUE" "${EVENT:-none}"
fi

[ -n "$OUTPUT" ] || exit 0

delimiter=$(random_token FMBODY)
while :; do
  case "$PR_BODY_VALUE" in
    *"$delimiter"*) delimiter=$(random_token FMBODY) ;;
    *) break ;;
  esac
done

{
  printf 'head_sha=%s\n' "$PR_HEAD_VALUE"
  printf 'body<<%s\n' "$delimiter"
  printf '%s\n' "$PR_BODY_VALUE"
  printf '%s\n' "$delimiter"
} >>"$OUTPUT"

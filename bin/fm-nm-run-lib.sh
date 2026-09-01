#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally consults branch
# OWNERSHIP (fm_nm_run_branch_ownership, below) and the active pipeline-owned
# exemption. Getting this wrong in either direction is unsafe: a false
# negative hides a genuinely parked run, and a false positive lets teardown
# act on a run it does not own.
#
# Ownership is the strongest primitive here and the only one that does not
# INFER: it reads the pipeline's own record of which run holds the branch.
# Prefer it wherever a branch may carry more than one run; the head and
# recency rules are the fallbacks for a CLI that does not publish it.
# Verified against no-mistakes v1.60.2.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# fm_nm_run_branch_ownership and fm_nm_run_is_pipeline_owned_active below
# carry the exemptions: a live run the pipeline currently owns binds without
# head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# --- branch ownership -------------------------------------------------------
# The branch's run OF RECORD, read from the `branch_sync.pipeline.run` scalar
# in captured `axi status` TOON.
#
# It names the run the pipeline last bound to this branch. It PERSISTS after
# the branch is released - observed live as `branch_sync.state: user_owned`
# still naming a cancelled run - so it is not by itself proof of a live
# holder. Callers may waive the head rule on it only for an ACTIVE run
# (fm_nm_run_is_active); for a terminal one it identifies which run the branch
# belongs to, and the head rule still decides whether that run describes the
# worktree's current code.
#
# This is the field that genuinely answers ownership. The alternatives all
# infer it and all get it wrong on a branch with more than one run: recency
# picks the newest row even when it is a terminal superseded one, and head
# equality rejects exactly the live run whose lane head never reached the task
# worktree. `branch_sync.pipeline.run` is the daemon's own binding, so it
# needs no inference at all.
#
# `run:` is also the top-level block header (an empty scalar), so fm_nm_field
# cannot be used here: the extractor is scoped by indentation to the
# `pipeline:` sub-block of the top-level `branch_sync:` block. Empty when the
# block is absent - a CLI without branch sync, or a branch with no pipeline
# binding - which callers must treat as UNKNOWN ownership, never as unowned.
fm_nm_branch_sync_pipeline_run() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" | awk '
    { line = $0; match(line, /^ */); ind = RLENGTH; key = substr(line, ind + 1) }
    ind == 0 { inbs = (key ~ /^branch_sync:/); inpipe = 0; next }
    inbs == 0 { next }
    ind <= 2 { inpipe = (key ~ /^pipeline:/); next }
    inpipe && key ~ /^run:/ { sub(/^run:[ \t]*/, "", key); print key; exit }
  ')
  fm_nm_strip_quotes "$s"
}

# Ownership verdict for the run described by captured `axi status` TOON $1,
# echoed as exactly one of:
#   owned   - branch_sync names THIS run as the branch's run of record. An
#             ACTIVE one is attributable with no head check, because a live
#             lane head is routinely not a git object in the task worktree. A
#             TERMINAL one still needs the head rule - see above.
#   foreign - branch_sync names a DIFFERENT run. This run has been superseded
#             (or belongs to another crew) and must never be attributed; the
#             run of record is the one to ask about instead.
#   unknown - no ownership record available. Callers fall back to the head
#             rules above; they must not read this as "not owned".
fm_nm_run_branch_ownership() {  # <toon-output>
  local owner id
  owner=$(fm_nm_branch_sync_pipeline_run "$1")
  id=$(fm_nm_strip_quotes "$(fm_nm_field "$1" id)")
  if [ -z "$owner" ] || [ -z "$id" ]; then printf 'unknown'; return; fi
  if [ "$owner" = "$id" ]; then printf 'owned'; else printf 'foreign'; fi
}

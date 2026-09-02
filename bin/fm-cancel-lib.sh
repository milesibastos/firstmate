#!/usr/bin/env bash
# fm-cancel-lib.sh - the single owner of cancelling a process tree you started.
#
# Sourced, never executed. Companion to fm-timeout-lib.sh: that library owns
# bounding a command's own runtime, this one owns propagating a CALLER'S
# cancellation down to work already under way.
#
# The two are deliberately separate. A bound is a deadline the command agreed
# to in advance; a cancellation arrives from outside at an arbitrary moment,
# and the work it must stop is spread across process groups the canceller never
# created. fm-timeout-lib.sh puts each bounded child in its own process group ON
# PURPOSE, so a hung grandchild still dies when the bound expires. That same
# isolation is why a caller's signal does not reach those children, which is the
# gap this library closes.
#
#   fm_cancel_descendant_pids <root-pid>...
#       Print every live descendant of the given roots, deepest first. Never
#       prints a root itself.
#
#   fm_cancel_tree_pids <root-pid>...
#       The same, with the still-live roots appended last.
#
#   fm_cancel_tree <root-pid> [grace-seconds]
#       TERM <root-pid> and every descendant, wait up to grace-seconds, then
#       KILL whatever is still there. Returns 0 when the tree is clear.
#
#   fm_cancel_trees <grace-seconds> <root-pid>...
#       fm_cancel_tree over several roots, one grace window shared across all of
#       them rather than paid once per root.
#
# Every walk reads the process table ONCE for all roots. Cancelling a fan-out
# happens while a caller is waiting on a bound it already considers blown, so a
# per-root read multiplied by a poll interval is real added latency on exactly
# the path that must be quick.
#
# THE IDENTITY RULE, which is the whole reason this file is narrow.
#
# A process may only be signalled when its identity is PROVEN, and the only
# proof this library accepts is descent from a pid THE CALLER STARTED and still
# holds a handle to - a `$!` it recorded, never a pid it looked up. Anything
# whose parent chain reaches that pid is the caller's own work by construction.
#
# That proof has an expiry a caller must respect: a root only proves ownership
# while it is still in flight. The instant a caller's own `wait` has reaped a
# root, the pid is dead and the OS is free to hand it to something else; from
# that moment the recorded pid proves nothing. A caller must therefore drop
# every pid from its recorded set as soon as it is reaped, and pass this
# library only roots still genuinely in flight - never a pid kept around as a
# history of what once ran. Passing a reaped pid back in here is the same
# identity violation as pattern matching: this library would still walk from it
# and sign whatever the OS has since made of it.
#
# Two things are therefore forbidden here, and both are forbidden because they
# select processes this library cannot prove it owns:
#
#   - Pattern matching (pgrep -f, ps | grep). A crewmate's argv carries its
#     entire brief, so a pattern naming any command a brief mentions matches
#     that unrelated agent. This is not hypothetical: it is how a repro for this
#     very library killed a neighbouring lane's agent and its pipeline client on
#     2026-09-01, and it is the third instance this fleet has seen of a
#     mechanism signalling a process it misidentified.
#   - Killing a process GROUP. fm-timeout-lib.sh hands each bounded child its
#     own group, so a group id seen from here belongs to one child, and a group
#     id from anywhere else belongs to something the caller did not create.
#
# This header owns that rule. bin/fm-brief.sh's generated crewmate contract
# carries one short reinforcement of it, because the scratch code that breaks it
# is written before any library is opened; change the rule here first, then that
# reinforcement.
#
# WHY THE ROOT MUST BE A CHILD, NOT $$. Walking from your own pid looks more
# convenient and is a trap: the `ps` and `awk` that perform the walk are
# themselves your descendants, so they land in their own result. The count then
# never reaches zero, every cancellation burns its full grace window, and the
# sweep signals pids belonging to the measurement rather than the work. Rooting
# each walk at a child makes those helpers siblings of the root instead of
# descendants of it, and the artifact disappears by construction rather than by
# filtering. fm_cancel_tree refuses $$ outright so the mistake cannot be made
# quietly.
#
# The residual window is reading the process table and then signalling from it:
# a descendant may exit and its pid be reused in between. That gap is
# irreducible for any process manager not holding pidfds, it is microseconds
# wide, and every pass re-reads the table rather than reusing a stale set, so a
# pid that stopped being a descendant is never carried into the next pass.
#
# Outside the contract: SIGKILL to the caller cannot be trapped, so a caller
# killed with -9 leaves this library unrun and its children alive. A caller that
# needs cancellation must be sent a catchable signal.
set -u

# Live descendants of <root-pid>, deepest first.
#
# Deepest-first matters: signalling a parent before its children can leave a
# grandchild reparented to init, where no descent walk can ever find it again.
# Leaves die first, so the chain stays intact while it is being taken apart.
#
# That ordering is necessary and NOT sufficient. On its own it creates the
# opposite defect - a parent released by its child's death runs its next line -
# which is why _fm_cancel_signal_trees freezes the tree before signalling it.
# Neither half works without the other.
fm_cancel_descendant_pids() {  # <root-pid>...
  local root roots=
  for root in "$@"; do
    case "$root" in
      ''|*[!0-9]*) return 1 ;;
    esac
    roots="$roots $root"
  done
  [ -n "$roots" ] || return 0
  # ps is the portable process table: macOS has no /proc, and Linux /proc would
  # need one open per pid. Both selected fields are numeric, so no argv is ever
  # read and no command text can influence which pids come back.
  ps -eo pid=,ppid= 2>/dev/null | awk -v roots="$roots" '
    BEGIN { nr = split(roots, R, " ") }
    {
      pid = $1 + 0
      ppid = $2 + 0
      if (pid > 0) { n++; P[n] = pid; PP[n] = ppid }
    }
    END {
      # Seed every root at depth 0. A root that is itself a descendant of
      # another root stays 0 and so is never emitted as a descendant, which
      # keeps overlapping roots from yielding the same pid twice.
      for (i = 1; i <= nr; i++) if (R[i] != "") depth[R[i] ""] = 0
      # Repeat to a fixpoint rather than assuming ps orders parents before
      # children; that ordering is not guaranteed on either platform.
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if (!((P[i] "") in depth) && ((PP[i] "") in depth)) {
            depth[P[i] ""] = depth[PP[i] ""] + 1
            changed = 1
          }
        }
      }
      maxd = 0
      for (p in depth) if (depth[p] > maxd) maxd = depth[p]
      # depth 0 is a root and is deliberately never printed here.
      for (d = maxd; d >= 1; d--) {
        for (p in depth) if (depth[p] == d) print p
      }
    }'
}

# Every live pid in the given trees, deepest first, roots last.
fm_cancel_tree_pids() {  # <root-pid>...
  local root
  fm_cancel_descendant_pids "$@" || return 1
  for root in "$@"; do
    kill -0 "$root" 2>/dev/null && printf '%s\n' "$root"
  done
  return 0
}

# Freeze the whole tree, THEN signal it, then let it run to die.
#
# THE CANCELLED WORK DOES NOT MERELY SURVIVE, IT COMPLETES BECAUSE IT WAS
# CANCELLED - KILLING THE CHILD IS WHAT RELEASES THE PARENT.
#
# That sentence inverts the assumption every reader brings to a cancellation
# path, so it is stated before the mechanism rather than after it. Signalling
# deepest-first WITHOUT freezing is worse than a missed kill: a victim's own
# child dies several kills before the victim's own signal arrives, and a shell
# reads that child's death as "the command finished" and executes its NEXT line
# in the gap. In the fixture that next line records the work as complete.
#
# The deepest-first ordering above is NOT the mistake, and must not be
# "corrected" by reversing it. Its reasoning still holds: signalling a parent
# first can leave a grandchild reparented to init where no descent walk can
# find it again. The real lesson is that ORDERING ALONE CANNOT SOLVE THIS,
# because any gap between two signals is exploitable by whatever runs in it.
# Freezing removes the gap instead of shrinking it, which is why it is the
# correct shape rather than merely a better order. A future change that makes
# the gap smaller is not a fix.
#
# The window is as wide as the number of pids signalled between a child and its
# parent, so denser trees fail more often. Measured on a victim shell with 40
# sibling sleeps, isolated from any caller: 16 of 50 non-vacuous runs ran the
# parent's next line, and 0 of 50 once frozen first.
#
# THE CONT IS REQUIRED, NOT A COURTESY. A stopped process does not act on a
# pending TERM until it resumes, so trimming the CONT does not reintroduce the
# race - it introduces a HANG: the tree sits frozen and every caller waits out
# its full grace before the KILL pass reaches them.
#
# Two hypotheses were investigated and DISPROVED before this one was found.
# They are recorded because a post-abort completion looks exactly like both,
# and the next reader will reach for the first one, as this author did:
#   1. Fork-after-sweep orphaning - a grandchild forked between the process
#      table read and signal delivery, reparented to init and unreachable by
#      descent. Disproved: the pid that recorded the post-abort completion was
#      in the discovered tree and was signalled.
#   2. An unrecorded child - the window between forking a worker and recording
#      its pid. Disproved: 25 runs comparing the caller's recorded pids against
#      the shell's own job table found no mismatch.
_fm_cancel_signal_trees() {  # <signal> <root-pid>...
  local sig=$1 pid pids
  shift
  pids=$(fm_cancel_tree_pids "$@")
  for pid in $pids; do kill -STOP "$pid" 2>/dev/null || true; done
  for pid in $pids; do kill "-$sig" "$pid" 2>/dev/null || true; done
  for pid in $pids; do kill -CONT "$pid" 2>/dev/null || true; done
}

_fm_cancel_live_count() {  # <root-pid>...
  local n
  n=$(fm_cancel_tree_pids "$@" | wc -l | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

fm_cancel_trees() {  # <grace-seconds> <root-pid>...
  local grace=$1 root waited=0 step=0.1 remaining
  shift
  case "$grace" in
    ''|*[!0-9.]*) grace=2 ;;
  esac
  # Refuse a root the caller did not start. $$ is the caller itself, and its
  # descendants include the walk's own helpers - see the header.
  for root in "$@"; do
    case "$root" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$root" != "$$" ] || return 1
  done
  [ "$#" -gt 0 ] || return 0

  _fm_cancel_signal_trees TERM "$@"

  # Poll rather than sleeping the whole grace: a tree that goes quietly should
  # not make every cancellation pay the worst case.
  while :; do
    remaining=$(_fm_cancel_live_count "$@")
    [ "$remaining" -gt 0 ] || return 0
    awk -v w="$waited" -v g="$grace" 'BEGIN { exit !(w < g) }' || break
    sleep "$step"
    waited=$(awk -v w="$waited" -v s="$step" 'BEGIN { printf "%.1f", w + s }')
  done

  # Fresh walk: only what is STILL in the tree earns the second signal.
  _fm_cancel_signal_trees KILL "$@"
  remaining=$(_fm_cancel_live_count "$@")
  [ "$remaining" -eq 0 ]
}

fm_cancel_tree() {  # <root-pid> [grace-seconds]
  fm_cancel_trees "${2:-2}" "$1"
}

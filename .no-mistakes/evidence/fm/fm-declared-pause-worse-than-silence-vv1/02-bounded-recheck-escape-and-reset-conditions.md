# Bounded recheck: consecutive rechecks and the demand-deep-inspection escape (fixed watcher)

Real bin/fm-watch.sh, declaration backdated 5000s, FM_PAUSE_RESURFACE_SECS=240,
FM_WEDGE_DEMAND_INSPECT_COUNT at its default of 3. Between rounds the wake is acked and
only the throttle marker mtime is backdated; its content is left untouched.

```

[fixed] consecutive bounded rechecks (FM_PAUSE_RESURFACE_SECS=240, FM_WEDGE_DEMAND_INSPECT_COUNT=3 default)
  recheck 1 wake payload: stale: test:fm-rounds (paused 5002s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)
  throttle marker content: resurfaced=1
  recheck 2 wake payload: stale: test:fm-rounds (paused 5008s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)
  throttle marker content: resurfaced=2
  recheck 3 wake payload: stale: test:fm-rounds (paused 5014s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds, demand-deep-inspection: this pane has been absorbed on the long cadence 3 times in a row - do not re-absorb on that evidence alone)
  throttle marker content: resurfaced=3
  recheck 4 wake payload: stale: test:fm-rounds (paused 5019s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds, demand-deep-inspection: this pane has been absorbed on the long cadence 4 times in a row - do not re-absorb on that evidence alone)
  throttle marker content: resurfaced=4
```

# Reset conditions for the recheck count (fixed watcher)

Throttle marker seeded at resurfaced=2 (100s old, so the cadence cannot fire), declaration
5000s old, one poll observed per case.

```
  mutation    : status append that stops declaring the wait (last line now working:)

[fixed] reset condition: status append stops declaring
  seeded      : .paused-resurfaced-test_fm-reset = resurfaced=2 (100s old), declaration 5000s old
  outcome     : absorbed
  wake payload: (none)
  markers after the poll:
    .paused-test_fm-reset  absent
    .stale-since-test_fm-reset present
    .wedge-escalations-test_fm-reset absent
    .paused-resurfaced-test_fm-reset absent
    .paused-rechecked-test_fm-reset absent
  mutation    : pane genuinely busy again, turn-ended fresh (below FM_BUSY_TURN_MAX_SECS), declaration still standing

[fixed] reset condition: pane busy again below its turn bound
  seeded      : .paused-resurfaced-test_fm-reset = resurfaced=2 (100s old), declaration 5000s old
  outcome     : absorbed
  wake payload: (none)
  markers after the poll:
    .paused-test_fm-reset  absent
    .stale-since-test_fm-reset absent
    .wedge-escalations-test_fm-reset absent
    .paused-resurfaced-test_fm-reset absent
    .paused-rechecked-test_fm-reset absent
  mutation    : none - declaration standing, pane still idle at the same hash

[fixed] reset condition: declaration standing, still idle, same hash
  seeded      : .paused-resurfaced-test_fm-reset = resurfaced=2 (100s old), declaration 5000s old
  outcome     : absorbed
  wake payload: (none)
  markers after the poll:
    .paused-test_fm-reset  present
    .stale-since-test_fm-reset absent
    .wedge-escalations-test_fm-reset absent
    .paused-resurfaced-test_fm-reset present content=resurfaced=2
    .paused-rechecked-test_fm-reset absent
  mutation    : pane idle but its hash changed (a ticking clock line), declaration standing

[fixed] reset condition: declaration standing, still idle, ticking hash
  seeded      : .paused-resurfaced-test_fm-reset = resurfaced=2 (100s old), declaration 5000s old
  outcome     : absorbed
  wake payload: (none)
  markers after the poll:
    .paused-test_fm-reset  present
    .stale-since-test_fm-reset absent
    .wedge-escalations-test_fm-reset absent
    .paused-resurfaced-test_fm-reset present content=resurfaced=2
    .paused-rechecked-test_fm-reset absent
```

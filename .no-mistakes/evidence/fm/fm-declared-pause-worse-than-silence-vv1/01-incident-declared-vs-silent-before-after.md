# Declared wait vs silence: the same fixture on the unfixed and fixed watcher

Fixture (identical across all runs): fake tmux pane "idle in the blocking gate call",
task meta kind=ship, seen-marker primed, stale hash already classified, wedge timer
backdated 500s (FM_STALE_ESCALATE_SECS=240), wedge-escalations=2, FM_PAUSE_RESURFACE_SECS=999.
A call counter wraps the fixture fm-crew-state.sh stub and appends one line per invocation.
Outcome "absorbed" = the real bin/fm-watch.sh completed a full poll cycle without waking.

## Unfixed watcher (base commit c01d2fb)
```

[unfixed] declared paused: + authoritative working
  status line : paused: waiting on the blocking fix-round call to return at the next gate
  crew state  : state: working · source: run-step · fix round running
  outcome     : wake
  wake payload: stale: test:fm-incident (idle 503s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)
  crew-state reads this poll: 1
  triage log  : 
  markers after the poll:
    .paused-test_fm-incident absent
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident present content=3
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident absent

[unfixed] silent working: + authoritative working (control)
  status line : working: running the fix round
  crew state  : state: working · source: run-step · fix round running
  outcome     : wake
  wake payload: stale: test:fm-incident (idle 502s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)
  crew-state reads this poll: 0
  triage log  : 
  markers after the poll:
    .paused-test_fm-incident absent
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident present content=3
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident absent

[unfixed] declared paused: + authoritative paused (positive control)
  status line : paused: waiting on the blocking fix-round call to return at the next gate
  crew state  : state: paused · source: status-log · awaiting the gate
  outcome     : absorbed
  wake payload: (none)
  crew-state reads this poll: 1
  triage log  : absorbed stale (paused, awaiting external, age 3s): test:fm-incident
  markers after the poll:
    .paused-test_fm-incident present
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident absent
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident present
```

## Fixed watcher (target commit 2abf48e)
```

[fixed] declared paused: + authoritative working
  status line : paused: waiting on the blocking fix-round call to return at the next gate
  crew state  : state: working · source: run-step · fix round running
  outcome     : absorbed
  wake payload: (none)
  crew-state reads this poll: 0
  triage log  : absorbed stale (paused, awaiting external, age 3s): test:fm-incident
  markers after the poll:
    .paused-test_fm-incident present
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident absent
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident absent

[fixed] silent working: + authoritative working (control)
  status line : working: running the fix round
  crew state  : state: working · source: run-step · fix round running
  outcome     : wake
  wake payload: stale: test:fm-incident (idle 502s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)
  crew-state reads this poll: 0
  triage log  : 
  markers after the poll:
    .paused-test_fm-incident absent
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident present content=3
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident absent

[fixed] declared paused: + authoritative paused (positive control)
  status line : paused: waiting on the blocking fix-round call to return at the next gate
  crew state  : state: paused · source: status-log · awaiting the gate
  outcome     : absorbed
  wake payload: (none)
  crew-state reads this poll: 0
  triage log  : absorbed stale (paused, awaiting external, age 3s): test:fm-incident
  markers after the poll:
    .paused-test_fm-incident present
    .stale-since-test_fm-incident absent
    .wedge-escalations-test_fm-incident absent
    .paused-resurfaced-test_fm-incident absent
    .paused-rechecked-test_fm-incident absent
```

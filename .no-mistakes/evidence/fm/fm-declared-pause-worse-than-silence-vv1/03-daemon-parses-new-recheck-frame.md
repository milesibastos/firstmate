# The new payload frame parsed by the real away-mode daemon

The third-recheck payload from the transcript above, fed through bin/fm-supervise-daemon.sh
handle_wake + housekeeping with a declaring status line.

```
payload fed to the daemon:
  stale: sess:fm-paused-frame-w1 (paused 5014s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds, demand-deep-inspection: this pane has been absorbed on the long cadence 3 times in a row - do not re-absorb on that evidence alone)
daemon state after handle_wake + housekeeping:
  .subsuper-paused-paused-frame-w1 present (window identity resolved to task paused-frame-w1)
  .subsuper-stale-paused-frame-w1 absent
  escalations: none
daemon log:
  [2026-09-02T11:11:54-0300] self-handle (paused): stale: sess:fm-paused-frame-w1 (paused 5014s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds, demand-deep-inspection: this pane has been absorbed on the long cadence 3 times in a row - do not re-absorb on that evidence alone) -> paused (awaiting external), rechecked on a long cadence: paused: waiting on the blocking fix-round call to return at the next gate
```

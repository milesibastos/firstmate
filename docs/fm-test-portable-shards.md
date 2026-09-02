# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

The whole remainder outgrew a single 20-minute runner, so `portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints are the longest run of each script across the `fm-test-timing-portable-serial-*` artifacts of four consecutive green `main` CI runs on 2026-09-01: [33576211441](https://github.com/milesibastos/firstmate/actions/runs/33576211441), [33573686506](https://github.com/milesibastos/firstmate/actions/runs/33573686506), [33571886334](https://github.com/milesibastos/firstmate/actions/runs/33571886334), and [33569567924](https://github.com/milesibastos/firstmate/actions/runs/33569567924).
Those runs measured the same 141 scripts, totalling 60.9 minutes of serial work on average and 64.9 minutes when each script takes its slowest observed run.
Sharding against the per-script maximum rather than the mean packs each shard for a slow runner rather than a lucky one; the same four runs show about two minutes of spread on a single shard's wall clock.
A script with no hint gets the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default, which tracks the measured per-script mean.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

Stale hints are still what put a shard against its cap, and they go stale in two ways at once.
Between 2026-08-21 and 2026-09-01 the lane grew from 42.4 minutes of measured work to 64.9 minutes across 141 scripts.
Eighteen of those scripts had no hint at all and were packed at the default: `tests/fm-backlog-atomicity.test.sh` alone really costs 121 s.
Hinted scripts also drifted, `tests/fm-public-followup.test.sh` from 36 s to 204 s.
Together that let shard 3 reach 19m19s of a 20-minute cap on a green run while shard 2 finished in 12m09s, and shard 4 cross the cap outright on two branches the same night.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

### Choosing the shard count

The 20-minute job cap is a hang tripwire at roughly 2x the healthy wall, not the expected end of the lane.
That is the sizing rule: pick the smallest shard count whose slowest projected shard stays at or under 10 minutes, measuring each script at its slowest observed run.

| Shards | Projected slowest shard |
|---:|---:|
| 4 | 16.2 min |
| 5 | 13.0 min |
| 6 | 10.8 min |
| **7** | **9.3 min** |
| 8 | 8.1 min |

Seven is the smallest count that holds; six misses by 0.8 minutes.
Raising the timeout instead was the wrong lever, because the lane's work grew 53% between 2026-08-21 and 2026-09-01: any budget sized to today's 16-minute shards is crossed again by the next comparable growth, while the shard count absorbs it.
The extra runners are close to free, since a shard's job setup costs about 15 seconds against 9.3 minutes of tests.

These are projections from the hints above, not observed walls: the seven-shard layout has not run yet.
Confirm them against the first green run's own timing artifacts, since the projection assumes the packing holds on real runners.

| Lane | Script count | Projected duration |
|---|---:|---:|
| `portable-serial-1of7` | 19 | 556 s (~9.3 min) |
| `portable-serial-2of7` | 18 | 556 s (~9.3 min) |
| `portable-serial-3of7` | 19 | 556 s (~9.3 min) |
| `portable-serial-4of7` | 22 | 556 s (~9.3 min) |
| `portable-serial-5of7` | 21 | 556 s (~9.3 min) |
| `portable-serial-6of7` | 20 | 556 s (~9.3 min) |
| `portable-serial-7of7` | 22 | 556 s (~9.3 min) |
| imbalance | | under 1 s |

The single longest script, `tests/fm-watch-triage.test.sh` at 258 s, is the floor for any shard count.

### Re-shard trigger

Re-shard when any shard's measured script time passes 10 minutes, rather than when a shard times out.
Check it against any green run's own artifacts:

```sh
gh run download <run-id> -R milesibastos/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '[.scripts[].duration_ms]|add/60000' /tmp/fm-serial/*.json
```

Refresh the hints first, since a shard is only over the threshold once its packing is honest; raise `PORTABLE_SERIAL_SHARDS` if the slowest shard is still over 10 minutes afterwards.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R milesibastos/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-7 | job `timeout-minutes: 20` | Each balanced shard projects to about 9.3 minutes of script time plus about 15 s of job setup, holding the roughly 2x hang-tripwire margin. The shard count, not this number, is what keeps that margin as the lane grows. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.

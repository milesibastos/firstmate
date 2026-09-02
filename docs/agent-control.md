# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `reconcile`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, whether it has a recovery-grade agent-state classifier able to prove an agent stopped, and whether its endpoint identity lives in the task record completely enough to rebuild.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |
| `reconcile` | Rebuild an endpoint that is provably gone, from the task's own record. It launches no agent and writes no metadata. | The recorded endpoint exists again, classifies agent-free, and its shell is in the recorded worktree - or the endpoint it just created is removed. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
muse is the one verified adapter that restores the cancelled prompt back into its composer as real text, so its interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts the recorded endpoint and worktree instead of creating either, clears the previous harness's per-task wiring, and arms a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Reconciling an endpoint whose host died

`missing` means the recorded endpoint is authoritatively absent, and every agent-facing verb refuses on it, because a target this home cannot resolve might still be alive elsewhere.
What was missing was a way out of that state.
When a terminal session hosting the fleet dies it takes every task's endpoint with it at once, and each guard then pointed at another: `exit` had no agent to stop, `relaunch` runs through `exit`, and `fm-spawn --relaunch` asked for the agent to be stopped first.

`reconcile` is the transition that ends that, and it deliberately adds one rather than loosening any of those guards.
It rebuilds the recorded endpoint and stops.
The endpoint returns to `dead`, the ordinary stop-and-relaunch path applies unchanged, and the replacement agent still has to satisfy every check it always did - including the worktree guard, which is the one standing between a recovery and an agent running in the wrong copy.

Before rebuilding anything it establishes four things:

1. The recovery-grade classifier reports `missing`.
   An `ambiguous` or `unreadable` endpoint is not a proven absence and refuses.
2. No endpoint anywhere on the host carries this task's label.
   This is the independent proof and the one that matters: a renamed session leaves the recorded target unresolvable while its agent runs on, so rebuilding then would put a second agent on one worktree.
   A definitively absent host is an authoritative zero; an unreadable inventory refuses.
3. The recorded worktree passes the same checkpoint a relaunch runs.
4. No live process holds that worktree.
   A held worktree and an unreadable holder check both refuse; where the holder check is unavailable the outcome discloses that it went unchecked rather than implying it passed, because the endpoint proofs are the load-bearing ones and a missing tool must not recreate the dead end this verb exists to open.

The rebuilt endpoint is then confirmed to resolve, to settle agent-free, and to have come up in the recorded worktree; if any of that fails, the endpoint just created is removed by its exact window id rather than left behind.
A brand-new pane is not agent-free the instant it exists - macOS runs `login` before it execs the shell - so the agent-free verdict is the settled one.

An endpoint that already exists is reported rather than replaced, and an existing agent-free endpoint sitting in the wrong directory is reported with the relaunch refusal it would otherwise cause, so those two refusals name each other instead of leaving the operator holding both.

Only tmux implements the rebuild.
Its endpoint identity is the recorded session and window name, so the task record holds everything a reconstruction needs.
Herdr classifies agent state but records opaque runtime workspace, tab, and pane ids, so rebuilding one would have to republish that record in the same transaction - a different mechanism, and unverified - and it is refused by name.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free and its shell is sitting in the recorded worktree, so a replacement can never join a live agent or start outside the copy holding the work.
  A `missing` endpoint is refused by that same guard, but named for what it is: there is no agent to stop, so the refusal points at `reconcile` rather than at `exit`.
- `reconcile` rebuilds only a proven absence, only where the task record holds the endpoint's whole identity, and never launches an agent - the guards above still decide whether one may start.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state | Endpoint rebuildable from the record |
| --- | --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes | no |
| zellij | yes | yes | yes | yes | no | no |
| cmux | yes | yes | yes | yes | no | no |
| orca | no | yes | yes | no | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for every verified harness, the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, the reconcile decisions and their refusals, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, and rollback after a failed launch.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
- `tests/fm-backend-tmux-smoke.test.sh` - the endpoint rebuild and label sightings against a real tmux server, including a task whose whole session died and a server that is gone entirely.

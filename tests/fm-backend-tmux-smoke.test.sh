#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
REBUILD_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  [ -n "${REBUILD_DIR:-}" ] && rm -rf "$REBUILD_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- endpoint-host recovery: label sightings and endpoint rebuild ------------
#
# The recovery transition that turns a `missing` endpoint back into a `dead`
# one, proven against the real server because both halves read and write real
# tmux inventory. The window killed above is still gone, so this starts from
# exactly the state a dead endpoint host leaves behind.

wait_agent_state_is() {  # <target> <wanted> [samples]
  local target=$1 wanted=$2 samples=${3:-100} i=0
  while [ "$i" -lt "$samples" ]; do
    [ "$(fm_backend_agent_state tmux "$target")" != "$wanted" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# wait_server_gone: block until the tmux server process named by <pid> has
# actually exited. `kill-server` (and a last-session `kill-session`) just
# self-signal the server and return - the requesting client's command
# completes before the server's event loop has processed that signal. A
# connection landing in that window is accepted then dropped mid-protocol,
# which is neither the ENOENT/ECONNREFUSED absence this suite checks for nor
# a live, readable server: settle past it instead of racing it.
wait_server_gone() {  # <pid> [samples]
  local pid=$1 samples=${2:-100} i=0
  while [ "$i" -lt "$samples" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

[ -z "$(fm_backend_tmux_label_sightings "$WINDOW")" ] \
  || fail "a killed window must leave no sighting of its label"
pass "real tmux: label sightings report nothing for a window that is gone"

# The case the sighting scan exists for: the agent is alive under a name the
# recorded target can no longer resolve. Rebuilding then would put a second
# agent on one worktree, so the scan must see it in the OTHER session.
tmux new-session -d -s renamed || fail "real tmux: could not create the second session"
tmux new-window -d -t "=renamed:" -n "$WINDOW" || fail "real tmux: could not create the renamed window"
sightings=$(fm_backend_tmux_label_sightings "$WINDOW") \
  || fail "label sightings failed against a readable server"
[ "$sightings" = "renamed:$WINDOW" ] \
  || fail "a live label in another session should be sighted as 'renamed:$WINDOW', got '$sightings'"
pass "real tmux: label sightings find the task label living in a differently named session"

tmux kill-session -t "=renamed" || fail "real tmux: could not remove the second session"

REBUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke-wt.XXXXXX")
REBUILD_REAL=$(cd "$REBUILD_DIR" && pwd -P)
wid=$(fm_backend_tmux_endpoint_rebuild "$TARGET" "$REBUILD_DIR") \
  || fail "fm_backend_tmux_endpoint_rebuild failed to rebuild the killed window"
case "$wid" in
  @[0-9]*) : ;;
  *) fail "endpoint rebuild should print a stable window id, got '$wid'" ;;
esac
tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "the rebuilt window is not visible in the recorded session"
# A brand-new pane runs its login program before it execs the shell, so the
# agent-free verdict is the settled one, not the instantaneous one.
wait_agent_state_is "$TARGET" dead \
  || fail "a rebuilt endpoint should settle as agent-free, got '$(fm_backend_agent_state tmux "$TARGET")'"
seen=$(fm_backend_tmux_current_path "$TARGET")
seen_real=$(cd "$seen" 2>/dev/null && pwd -P) || seen_real=$seen
[ "$seen_real" = "$REBUILD_REAL" ] \
  || fail "the rebuilt pane should start in the requested directory '$REBUILD_REAL', got '$seen_real'"
pass "real tmux: endpoint rebuild restores the recorded window agent-free in the requested directory"

if fm_backend_tmux_endpoint_rebuild "$TARGET" "$REBUILD_DIR" 2>/dev/null; then
  fail "endpoint rebuild must refuse a window name that already exists rather than adopting it"
fi
if fm_backend_tmux_endpoint_rebuild "$TARGET" "$REBUILD_DIR/not-a-directory" 2>/dev/null; then
  fail "endpoint rebuild must refuse a directory that does not exist"
fi
pass "real tmux: endpoint rebuild refuses an existing window and a missing directory"

# The stable window id addresses one exact window with no name resolution, which
# is what an undo of a just-created endpoint needs.
fm_backend_tmux_kill "$wid" || fail "fm_backend_tmux_kill should accept a stable window id"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window addressed by its id"
fi
pass "real tmux: a stable window id removes exactly the window it names"

# The observed incident: the whole session went with the terminal that hosted
# it. The rebuild has to restore the recorded SESSION too, not just the window.
server_pid=$(tmux display-message -p -t "=$SESSION:" '#{pid}') \
  || fail "real tmux: could not read the server pid before killing the recorded session"
tmux kill-session -t "=$SESSION" || fail "real tmux: could not remove the recorded session"
wait_server_gone "$server_pid" \
  || fail "real tmux: the server did not exit after its last session was killed"
tmux has-session -t "=$SESSION" 2>/dev/null \
  && fail "the recorded session should be gone before the whole-host rebuild"
wid=$(fm_backend_tmux_endpoint_rebuild "$TARGET" "$REBUILD_DIR") \
  || fail "endpoint rebuild failed to restore a task whose whole session was gone"
tmux has-session -t "=$SESSION" 2>/dev/null \
  || fail "endpoint rebuild did not recreate the recorded session"
wait_agent_state_is "$TARGET" dead \
  || fail "a rebuilt endpoint in a recreated session should settle as agent-free"
pass "real tmux: endpoint rebuild recreates the recorded session when the whole host is gone"

# An absent server is an authoritative zero, not an unreadable inventory: there
# is nothing a task could still be running on.
server_pid=$(tmux display-message -p -t "=$SESSION:" '#{pid}') \
  || fail "real tmux: could not read the server pid before the final kill-server"
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
wait_server_gone "$server_pid" \
  || fail "real tmux: the server did not exit after kill-server"
sightings=$(fm_backend_tmux_label_sightings "$WINDOW") \
  || fail "label sightings should succeed against a definitively absent server"
[ -z "$sightings" ] || fail "an absent server should report no sightings, got '$sightings'"
pass "real tmux: an absent server is an authoritative zero sightings, not an unreadable inventory"

cleanup_all
trap - EXIT

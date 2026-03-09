# Subagent Memory Retention Findings

## Summary

This document records a performance bug observed in the Codex desktop app when repeatedly spawning
subagents from a long-lived app session.

The issue is not a one-off spike from a single large tool output. It is a cumulative retention bug
where per-thread app-server state survives after subagent completion and explicit `close_agent`
cleanup.

## Live Proof

A live Codex app session was used as the workload generator. The app-server process was sampled
after a fresh restart, after a realistic six-agent fan-out, after explicit `close_agent`, and
after a second realistic six-agent fan-out.

Observed `app-server` RSS:

- Fresh baseline: about 243 MB
- After first realistic six-agent batch completed: about 330 MB
- After explicit `close_agent` on that batch: still about 330 MB
- After second realistic six-agent batch completed: about 394 MB
- After explicit `close_agent` on the second batch: still about 395 MB

This shows roughly 150 MB of resident growth after two normal fan-out cycles with no recovery after
explicit close. That is a performance bug, not expected steady-state working set.

## Root Causes

The retained memory came from multiple lifecycle gaps:

1. `ThreadStateManager::remove_connection()` removed connection bookkeeping but intentionally left
   zero-subscriber thread listeners and per-thread state resident.
2. `thread/unsubscribe` only removed a thread from `ThreadManager` when shutdown completed
   successfully; timeout or submit failure left the thread loaded indefinitely.
3. `ShutdownComplete` only marked `ThreadWatchManager` state as not loaded. It did not reconcile
   stale app-server state when the core `ThreadManager` entry had already been removed by
   `close_agent` or other teardown paths.

These bugs affect performance because subagent fan-out reconstructs history, allocates app-server
thread state, and then fails to release it consistently.

## Fixes In This Change

This change makes teardown more aggressive in the exact cases that caused the retained-memory
ratchet:

- Connection close now identifies orphaned zero-subscriber threads and routes them through the same
  teardown path as explicit unsubscribe.
- Last-subscriber teardown now force-unloads threads from `ThreadManager` when shutdown submit
  fails or times out, preferring bounded memory over invisible zombie threads.
- `ShutdownComplete` now reconciles stale app-server bookkeeping when the underlying core thread is
  already gone, removing retained thread-state/watch-state entries and notifying clients with
  `ThreadClosed`.
- `fork_context=true` no longer has to reread and reparse the parent rollout JSONL when the parent
  thread is still live. The app now snapshots the parent session’s in-memory transcript and
  hydration metadata directly, then uses that snapshot to seed the child thread.
- clients can now opt into typed-only notifications via
  `initialize.params.capabilities.typedNotificationsOnly`, which suppresses legacy
  `codex/event/*` notifications on that connection and reduces duplicate event delivery cost.
- `exec` is now the first real client path using `typedNotificationsOnly`, with typed lifecycle
  notifications translated back into the minimal legacy event shapes its existing event processor
  expects, including interrupted turns and typed error notifications.

## Regression Coverage

Regression tests added in this change verify:

- removing the last connection reports orphaned threads for teardown;
- `ShutdownComplete` cleans up stale thread state, clears listener cancellation state, and emits a
  `ThreadClosed` notification for subscribed clients.

## Broader Performance Findings

The lifecycle leak above was a real P0 performance bug because memory ratcheted upward after normal
subagent fan-out. Profiling also surfaced broader bottlenecks that are not fixed in this change:

1. `fork_context=true` is expensive by construction.
   Subagent spawn currently forces rollout materialization, loads and parses the full parent JSONL
   rollout, clones the full item list, injects synthetic spawn output, and replays that history in
   the child.

2. Resume and fork eagerly materialize entire rollout history.
   `RolloutRecorder::load_rollout_items()` builds a full `Vec<RolloutItem>`, and reconstruction then
   scans and rehydrates that history into `ContextManager.items`.

3. App-server event delivery duplicates work.
   The listener loop maintains per-thread history, emits generic `codex/event/*` notifications, and
   then emits typed v2 notifications for many of the same state transitions.

4. Notification fanout scales with `events x subscribers`.
   Per-event payload building plus per-connection cloning becomes expensive during high-rate tool
   output, reasoning deltas, and subagent-heavy sessions.

5. Logging and state persistence add write amplification.
   SQLite WAL writes are not the core issue, but repeated event/log serialization plus rollout JSONL
   replay creates compounding I/O and allocation cost under bursty fan-out.

## Extra Optimization In This Change

This change also removes one low-risk CPU cost in the app-server listener loop:

- generic `codex/event/*` JSON serialization now uses `serde_json::to_value(&event)` instead of
  cloning the whole `Event`;
- the app-server now skips generic event JSON serialization entirely when there are no subscribed
  connections for that thread.
- the SQLite `LogDbLayer` now defaults to `INFO` instead of `TRACE`, with
  `CODEX_APP_SERVER_LOG_DB_LEVEL` available as an override when deep DB-backed tracing is needed.
- the SQLite `LogDbLayer` now returns immediately when its bounded queue is already full, so burst
  logging no longer pays allocation/serialization cost for entries that were going to be dropped
  anyway.

This does not change API behavior, but it reduces wasted work on busy threads and on stale listener
paths.

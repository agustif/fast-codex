# Fast Codex Fork Ledger

This document records the long-lived deltas that `agustif/fast-codex` carries on top of
`openai/codex`.

## Fork policy

- `main` should stay close to `upstream/main`
- permanent fork behavior changes must be listed here
- experimental work should land through small branches first and only move to `main` after local
  validation
- upstream is treated as a vendor source, not as an expected code-review path for this fork

## Permanent deltas on `main`

### Fork maintenance

- `scripts/sync-upstream.sh`
  - safely syncs the fork target branch with `upstream/main`
  - refuses to run on a dirty worktree
  - optionally pushes after syncing
  - prints remaining local delta branches after syncing

### App-server disconnect cleanup

Files:

- `codex-rs/app-server/src/thread_state.rs`
- `codex-rs/app-server/src/codex_message_processor.rs`
- `codex-rs/app-server/src/bespoke_event_handling.rs`

Behavior:

- last-subscriber disconnects now unload orphaned threads instead of leaving them resident
- teardown is shared between unexpected disconnect and explicit `thread/unsubscribe`
- late `ShutdownComplete` reconciles stale thread/watch bookkeeping when the core thread is already
  gone

### Typed notifications fast path

Files:

- `codex-rs/app-server-protocol/src/protocol/common.rs`
- `codex-rs/app-server-protocol/src/protocol/v1.rs`
- `codex-rs/app-server-client/src/lib.rs`
- `codex-rs/app-server/src/transport.rs`
- `codex-rs/app-server/src/message_processor.rs`
- `codex-rs/app-server/src/in_process.rs`
- `codex-rs/exec/src/lib.rs`

Behavior:

- clients can opt into `typedNotificationsOnly`
- legacy `codex/event/*` notifications can be suppressed on that connection
- `exec` uses the typed path and translates typed lifecycle notifications back into the legacy
  event shapes it still expects internally

### Subagent fork / rollout optimizations

Files:

- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/core/src/codex.rs`
- `codex-rs/core/src/agent/control.rs`
- `codex-rs/core/src/rollout/recorder.rs`
- `codex-rs/core/src/codex_tests.rs`

Behavior:

- live-parent `fork_context=true` can use an in-memory fork snapshot instead of rereading and
  reparsing the parent rollout JSONL
- rollout loading is streamed line-by-line instead of full-file `read_to_string`

### Startup and logging reductions

Files:

- `codex-rs/core/src/file_watcher.rs`
- `codex-rs/app-server/src/lib.rs`
- `codex-rs/state/src/log_db.rs`

Behavior:

- `FileWatcher` is lazy instead of eager
- app-server startup avoids an unnecessary full config build for cloud requirement preload
- DB-backed app-server logging defaults to `INFO`
- log DB enqueue drops now short-circuit immediately when the queue is already full

## Investigation docs carried in the fork

- `codex-rs/docs/performance_investigation_2026-03-09.md`
- `codex-rs/docs/subagent_memory_retention.md`

These docs record:

- live packaged-app process measurements
- sampling and flamegraph artifact paths
- validation history
- the reasoning behind the adopted fork deltas

## Upstream context

- the disconnect-retention bug was reported upstream in `openai/codex#14137`
- upstream responded that they no longer generally accept external PRs and may not prioritize this
  bug soon
- this fork therefore carries the relevant fixes directly

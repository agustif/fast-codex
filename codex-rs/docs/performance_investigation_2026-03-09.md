# Performance Investigation Log (2026-03-09)

## Scope

This document captures the full investigation performed against:

- the live packaged Codex desktop app on macOS, to observe real process RSS / CPU / event behavior;
- a fresh source clone of `openai/codex` at `/Users/af/openai-codex-memory-fix2`;
- the `codex-rs` crates, primarily `app-server`, `core`, and `state`.

The investigation started with a user-reported memory blow-up during Codex.app subagent use and
then expanded into a broader performance review.

## Fresh Clone

- Repo path: `/Users/af/openai-codex-memory-fix2`
- Initial HEAD at clone time: `06f82c1`

## What Was Changed

### Lifecycle / memory retention fixes

Files changed:

- `codex-rs/app-server/src/thread_state.rs`
- `codex-rs/app-server/src/codex_message_processor.rs`
- `codex-rs/app-server/src/bespoke_event_handling.rs`

Behavioral fixes:

1. Connection close now reports orphaned zero-subscriber thread IDs instead of silently retaining
   the associated thread listener state forever.
2. App-server now tears down zero-subscriber threads through the same shutdown path used by
   explicit unsubscribe.
3. If shutdown submit fails or times out for a thread with no subscribers, the app-server now
   force-unloads that thread from `ThreadManager` and `ThreadWatchManager` to reclaim memory.
4. `ShutdownComplete` now reconciles stale app-server bookkeeping when the core thread is already
   gone, removing retained thread/watch state and emitting `ThreadClosed`.

### CPU / event-loop optimization

Files changed:

- `codex-rs/app-server/src/codex_message_processor.rs`
- `codex-rs/app-server/src/lib.rs`
- `codex-rs/app-server/src/message_processor.rs`
- `codex-rs/app-server/src/transport.rs`
- `codex-rs/app-server/src/in_process.rs`
- `codex-rs/app-server-protocol/src/protocol/v1.rs`
- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/core/src/agent/control.rs`
- `codex-rs/core/src/codex.rs`
- `codex-rs/core/src/codex_tests.rs`

Behavioral/performance improvement:

1. Generic `codex/event/*` serialization now uses `serde_json::to_value(&event)` instead of
   cloning the whole `Event`.
2. Generic `codex/event/*` JSON serialization is skipped entirely when the thread has no subscribed
   connections.
3. The SQLite-backed app-server log sink now defaults to `INFO` instead of `TRACE`, with
   `CODEX_APP_SERVER_LOG_DB_LEVEL` available as an opt-in override for deeper DB-backed tracing.
4. `LogDbLayer::on_event()` now short-circuits immediately when its bounded queue is already full,
   so burst logging no longer allocates/serializes entries that would be dropped anyway.
5. `fork_context=true` now uses an in-memory fork snapshot when the parent thread is live, instead
   of rereading and reparsing the parent rollout JSONL from disk.
6. Clients can now set `initialize.params.capabilities.typedNotificationsOnly = true` to suppress
   legacy `codex/event/*` notifications for that connection while keeping typed v2 notifications.
7. `exec` now opts into `typedNotificationsOnly` and maps typed lifecycle notifications back into
   the minimal legacy `EventMsg` shapes its event processor already understands, including
   interrupted turns and typed error notifications.
8. App-server startup no longer does an initial full `ConfigBuilder::build()` just to preload cloud
   requirements. That first pass now uses lighter config-layer loading plus `ConfigToml`
   deserialization, and the real `ConfigBuilder` run happens once.
9. `FileWatcher` now initializes lazily: creating a `ThreadManager` no longer creates the OS
   watcher or spawns the watcher loop until a real root is registered.

### Rollout loading optimization

Files changed:

- `codex-rs/core/src/rollout/recorder.rs`

Behavioral/performance improvement:

1. Rollout resume no longer reads the entire JSONL file into one large `String` via
   `read_to_string`.
2. Rollout parsing now streams line-by-line with `tokio::io::BufReader`, reducing peak allocation
   pressure and removing a full-file copy from the resume/fork path.

### Documentation added

- `codex-rs/docs/subagent_memory_retention.md`
- `codex-rs/docs/performance_investigation_2026-03-09.md` (this file)

## Validation Completed

Completed successfully:

- `just fmt`
- targeted regressions:
  - `cargo test -p codex-app-server shutdown_complete_cleans_up_stale_thread_state_and_notifies_clients -- --nocapture`
  - `cargo test -p codex-app-server removing_last_connection_reports_orphaned_thread -- --nocapture`
  - `cargo test -p codex-core record_initial_history_forked_snapshot -- --nocapture`
  - `cargo test -p codex-app-server-client initialize_params_preserves_typed_notifications_only -- --nocapture`
  - `cargo test -p codex-exec --lib -- --nocapture`
- full crate test suite:
  - `cargo test -p codex-app-server`
  - `cargo test -p codex-app-server-protocol`
  - `cargo test -p codex-app-server-client`
- lint/fix:
  - `just fix -p codex-app-server`
  - `just fix -p codex-state`

Attempted but interrupted:

- `cargo test -p codex-core`
- `cargo bloat -p codex-app-server --release --bin codex-app-server --crates -n 20`
- `cargo bloat -p codex-core --release --crates -n 20`
- `cargo bloat -p codex-core --lib --crates -n 20 --profile dev` (unsupported: `cargo bloat` only handles bin/dylib/cdylib)

The interrupted commands were user-aborted, not code failures.

Known unrelated failure during broader validation:

- `cargo test -p codex-core` currently fails two environment-sensitive shell tests on this machine:
  `shell::tests::detects_zsh` and `shell::tests::fish_fallback_to_zsh`, because the local zsh path
  resolves to `/opt/homebrew/bin/zsh` rather than the hard-coded `/bin/zsh` expected by those
  tests.

## Tools Installed

Installed during this investigation:

- `inferno`
- `samply`
- `cargo-llvm-lines`
- `cargo-flamegraph`

Already available / confirmed:

- `cargo-bloat`
- `/usr/bin/sample`
- `/usr/bin/xctrace`
- `/usr/sbin/dtrace`

Additional analysis commands completed successfully:

- `cargo llvm-lines -p codex-app-server --bin codex-app-server | head -n 80`
- `cargo llvm-lines -p codex-core --lib | head -n 80`
- `cargo bloat -p codex-app-server --bin codex-app-server --crates -n 20 --profile dev`

## Live Packaged-App Measurements

### First live session (before fresh clone work)

Process snapshot before stress:

- main app PID `642`: RSS about `492 MB`
- renderer PID `1171`: RSS about `1.0 GB`
- app-server PID `1224`: RSS about `675 MB`

After a simple 6-subagent batch:

- app-server rose from about `675 MB` to about `713 MB`

After a realistic 6-agent code-reading batch in a later fresh session:

- fresh app-server baseline after restart: about `243 MB`
- after first realistic 6-agent batch completed: about `330 MB`
- after explicit `close_agent`: still about `330 MB`
- after second realistic 6-agent batch completed: about `394-395 MB`
- after explicit `close_agent` again: still about `395 MB`

This was the strongest direct proof that stale thread/app-server bookkeeping was a real
performance bug and not just temporary allocator noise.

### Later live profiling pass

In a later live session, before starting a new stress wave, the packaged app was already carrying a
very large resident set:

- app-server PID `98473`: about `810 MB` RSS
- renderer PID `98448`: about `696 MB` RSS
- GPU helper PID `98445`: about `1.1 GB` RSS

During the subsequent sampling window:

- app-server reached about `846 MB` physical footprint with allocator usage dominated by
  `MALLOC_SMALL` and `MALLOC_LARGE`
- renderer reached about `923 MB` physical footprint and about `2.7 GB` resident virtual memory
- renderer RSS briefly climbed to about `1.33 GB`

This confirmed that the stale-thread leak was only one part of the problem: once the app enters an
inflated state, normal activity can keep both the app-server and renderer at very high resident
footprints.

## Sampling / Flamegraph Artifacts

Live packaged-app samples:

- `/tmp/codex_appserver_idle.sample.txt`
- `/tmp/codex_appserver_load.sample.txt`
- `/tmp/codex_renderer_idle.sample.txt`
- `/tmp/codex_renderer_load.sample.txt`
- `/tmp/appserver_live.sample.txt`
- `/tmp/renderer_live.sample.txt`
- `/tmp/gpu_live.sample.txt`

Generated flamegraphs:

- `/tmp/codex_appserver_idle.svg`
- `/tmp/codex_appserver_load.svg`
- `/tmp/codex_renderer_load.svg`

Source-built symbolic sample:

- `/tmp/codex_appserver_tests.sample.txt`
- `/tmp/codex_appserver_tests.folded`
- `/tmp/codex_appserver_tests.svg`

Notes:

- The packaged app’s bundled `codex` binary is stripped, so live app-server flamegraphs do not
  recover enough Rust symbols to be fully diagnostic.
- `samply` was installed successfully, but attach-to-pid profiling of the running packaged app
  failed on this Mac because `task_for_pid` entitlements were missing. Live profiling therefore
  relied on `/usr/bin/sample` and `vmmap`.
- The source-built symbolic capture was useful for confirming that the `--test all` process was
  mostly waiting in its harness and was therefore not a good workload for identifying steady-state
  hot paths.

## Code Size / Monomorphization Findings

### `cargo bloat` on `codex-app-server` (dev profile)

Top crate-level contributors in the `codex-app-server` binary text section:

- `codex_core`: about `22.8 MiB` (`26.0%` of `.text`)
- `starlark`: about `9.6 MiB` (`11.0%`)
- `codex_app_server`: about `7.2 MiB` (`8.1%`)
- `codex_network_proxy`: about `4.7 MiB` (`5.4%`)
- then `rmcp`, `reqwest`, `codex_app_server_protocol`, `opentelemetry_sdk`, `rustls`,
  `regex_automata`, `sqlx_sqlite`, and `image`

Implication:

- `codex_core` dominates binary weight, so app-server performance work cannot stop at the
  `app-server` crate boundary.
- `starlark` is a major structural dependency cost and should be treated as a heavyweight runtime
  and compile-time component.
- network/protocol/otel/sqlite/image stacks all materially contribute to the binary and should be
  considered part of the app-server hot path, not incidental extras.

### Additional implication from `cargo llvm-lines`

`codex-core` is structurally heavy in exactly the same areas the runtime profiling pointed at:

- Tokio task/runtime scaffolding
- JSON and TOML deserialization
- config/profile parsing
- schema generation
- async spawn / boxed-future glue

This reinforces that runtime bottlenecks around startup, rollout replay, and thread/task churn are
not accidents; they sit on top of some of the largest monomorphized regions in the codebase.

### `cargo llvm-lines` on `codex-app-server`

Top code-volume symbols were concentrated in:

- Tokio current-thread runtime/block-on machinery
- thread-local access and scheduler context switching
- CLI parsing / clap-derived argument plumbing
- some app-server entrypoint glue

Implication:

- the app-server binary pulls in significant executor and CLI machinery even before serving a real
  request;
- startup and narrow request paths are paying for a large amount of runtime scaffolding.

### `cargo llvm-lines` on `codex-core`

Top code-volume concentrations were in:

- Tokio task/core/harness creation and polling
- `serde_json`, `serde_path_to_error`, and `toml` deserialization
- `ConfigToml` visitor/deserialization logic
- schema generation (`schemars`)
- task spawning / boxed futures / result adaptation

Implication:

- config parsing and schema-heavy deserialization are not just correctness code; they are a major
  structural cost in `codex_core`;
- async task construction / polling glue is a large part of the library’s monomorphized surface;
- any startup path that repeatedly builds config or repeatedly reconstructs history is amplifying
  one of the largest code-volume and likely cache-miss-heavy regions in the codebase.

## Architecture Findings

### Confirmed P0 issues

1. Stale thread retention in app-server lifecycle bookkeeping.
   This was the original bug and is now fixed in this clone.

2. Full rollout replay on `fork_context=true` subagent spawn.
   Parent rollout is materialized, read, parsed, cloned, and replayed into the child.

3. Whole-rollout resume/fork loading.
   Even after removing `read_to_string`, resume/fork still fully materializes a `Vec<RolloutItem>`
   and then reconstructs history from it.

4. Duplicate event-delivery work in app-server.
   Many events are represented both as generic `codex/event/*` payloads and as typed v2
   notifications.

5. Per-event reducer work under thread-state mutex.
   `ThreadHistoryBuilder` is updated for every event on the hot path.

6. TRACE-level feedback logging on hot app-server paths.
   The feedback logger still captures at high fidelity, and the DB-backed log layer was originally
   also wired at `TRACE`. This clone now lowers the DB sink to `INFO` by default.

7. Eager manager graph initialization.
   The startup graph is still eager, but the constructors are not equally expensive. After the
   lazy watcher change, `FileWatcher::new` is much cheaper; `SkillsManager::new` still installs
   system skills eagerly, and `ModelsManager::new` still loads bundled catalog/cache state eagerly.

Concrete constructor audit:

- `PluginsManager::new` is cheap: it stores `codex_home`, constructs a `PluginStore`, and allocates
  an empty cache.
- `McpManager::new` is cheap: it only stores the `PluginsManager` handle.
- `SkillsManager::new` is not free: it eagerly calls `install_system_skills`, which checks the
  on-disk marker, computes the embedded-skills fingerprint, and may rewrite the cache.
- `FileWatcher::new` used to be expensive because it created the OS watcher and spawned the async
  event loop immediately. This clone now defers that work until the first actual registration.
- `ModelsManager::new` is not free: it builds cache state and eagerly loads the bundled model
  catalog when no external catalog is supplied.

### Likely P1 issues

1. Notification fanout scales roughly with `events x subscribers`.
2. SQLite WAL write amplification under bursty fan-out.
3. In-process startup paths are expensive even for narrow typed requests.
4. Renderer side appears dominated by V8/module/code-cache activity rather than React paint.

## Subagent Findings

### Wave: lifecycle / retention diagnosis

#### `Pasteur` (`019cd12e-1f90-71f2-8c06-0b7ab3d923db`)

- `ThreadState::set_listener()` plus `track_current_turn_event()` is a hot per-event lifecycle
  path.
- `ThreadStateManager::remove_connection()` is a fan-out hotspot on disconnect.
- `shutdown_thread_with_no_subscribers()` is the main teardown bottleneck.
- `ShutdownComplete` stale-state reconciliation is critical for subagent cleanup.

#### `Laplace` (`019cd12e-228b-7b91-b491-7c354c150c96`)

- `spawn_agent` does much more than thread creation.
- `fork_context=true` dominates spawn cost because it forces parent rollout materialization and full
  history replay into the child.
- Batch worker concurrency maps directly to live subagent thread count.

#### `Franklin` (`019cd12e-26ae-73c2-b37b-39d95dcbdd0d`)

- `RolloutRecorder::load_rollout_items()` eagerly materialized the full rollout.
- `get_rollout_history()` wraps the full retained item set as `InitialHistory::Resumed`.
- `reconstruct_history_from_rollout()` adds more passes over long histories.
- `record_initial_history()` rehydrates the rebuilt response-item transcript back into session
  history.

#### `Ohm` (`019cd12e-2abd-7e51-a987-400669f9e2e4`)

- Summarized the applied lifecycle fixes and the pre-fix memory proof.
- Identified remaining P0s:
  - default SQLite trace logging on hot path
  - eager manager graph initialization

#### `Erdos` (`019cd12e-2e32-7e83-8c7f-29a52352c6cd`)

- Listener loop duplicated work by serializing/cloning events for generic notifications and again
  for typed notifications.
- Notification fanout cost scales per subscriber.
- The protocol surface is extremely delta-heavy.
- Suggested removing double delivery and coalescing high-rate deltas.

#### `Faraday` (`019cd12e-31dd-7202-b61f-458cbf62c0e9`)

- `state` runtime opens both state and log DBs in WAL mode with multiple pooled connections.
- `LogDbLayer::on_event()` serializes on every event before dropping under pressure.
- Repeated “load / serialize / reconcile / query” loops compound around thread lifecycle and
  history operations.

### Wave: broader architecture sweep

#### `Helmholtz` (`019cd13b-dc8d-7371-a197-57b126fefd45`)

- Flagged these P0 app-server architectural bottlenecks:
  - TRACE-level SQLite log layer on hot path
  - single global outbound router + serialized per-connection fanout
  - duplicate generic + typed event delivery
  - per-event `ThreadHistoryBuilder` reducer work under mutex
  - too many high-frequency delta notifications

#### `Heisenberg` (`019cd13b-df6a-78a0-9cdc-a92064938116`)

- Flagged these P0 core bottlenecks:
  - full parent-rollout round trip for `fork_context=true`
  - whole-rollout materialization for resume/fork
  - multi-pass history replay / reconstruction
  - fork startup write amplification
  - eager `ThreadManager` initialization graph
  - serialized spawn path around watcher registration and `SessionConfigured`

#### `Nietzsche` (`019cd13b-e91c-7e02-b4b6-5f1ea7a10639`)

- Flagged these P0 persistence bottlenecks:
  - TRACE feedback logger plus TRACE SQLite log sink together on hot path
  - per-event `LogEntry` serialization before queue/drop behavior
  - eager dual-DB initialization / migration before first useful request
  - mutex-heavy ring-buffer feedback path

#### `Dirac` (`019cd13b-e3ee-7bf3-8dd0-f558e2d5ee85`)

- Interpreted renderer-side live samples as V8/module-loader churn rather than React paint work.
- Reconfirmed that upstream event volume and double delivery are the best leverage points for
  renderer-side performance.

## Best-Practice Research Notes

Current guidance confirmed from primary sources:

- Rust Performance Book:
  - use real profiling data before optimization;
  - prefer reducing allocation/copying and unnecessary work before micro-tuning.
- `samply` / macOS:
  - use symbolized sampling on local debug builds for function-level flamegraphs.
- `cargo-flamegraph` / `inferno`:
  - useful once a representative workload is identified.
- `tokio-console`:
  - high value for async task stalls / scheduling issues, but needs instrumentation in the app.
- `cargo-bloat` / `cargo-llvm-lines`:
  - useful for code-size / monomorphization hotspots, but best run on explicitly targeted bins/libs.

## Commands That Were Explored

Successfully used:

- `ps`, `top`, `vmmap`, `sample`
- `inferno-collapse-sample`, `inferno-flamegraph`
- `cargo test -p codex-app-server`
- targeted `cargo test` filters
- `just fmt`
- `just fix -p codex-app-server`

Attempted but less useful:

- symbol-rich sample of `cargo test --test all` process:
  - mostly showed harness waiting, not representative hot work
- `cargo bloat` without sufficiently narrow targeting:
  - too slow for interactive iteration in this session
- `cargo llvm-lines -p codex-app-server` without explicit target:
  - required `--bin codex-app-server` or `--lib`

## Recommended Next Fixes

Highest leverage next steps after the fixes already landed:

1. Stop double delivery for events that already have typed v2 notifications.
2. Reduce / gate TRACE-level logging on the app-server hot path.
3. Lazify `ThreadManager` startup dependencies where possible, starting with `FileWatcher` and
   any eagerly installed system-skill setup that does not need to run before the first real turn.
4. Extend `typedNotificationsOnly` to additional real clients and then begin deleting legacy
   `codex/event/*` dependencies behind that compatibility gate.
5. Continue reducing the remaining resume/fork replay cost beyond the new live-parent in-memory
   fork snapshot path.
6. Introduce batching/coalescing for the noisiest delta notification families.

## Status At End Of This Log

The fresh clone still has uncommitted local changes for the fixes and docs listed above.
No commit or PR was created in this investigation.

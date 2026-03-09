# Fast Codex Review (2026-03-10)

This note captures the fork state after:

- merging the fork-owned maintenance and performance deltas into `main`
- syncing the fork with the latest `upstream/main`
- auditing the branch and PR state

## Current state

- `main` includes all currently adopted fork work
- `main` has been merged with `upstream/main`
- the fork currently sits ahead of `upstream/main` only by intentional fork deltas

## Branch and PR hygiene

Branches created for the current fork work were cleaned up:

- `chore/add-upstream-sync-script` deleted locally and on `origin`
- `docs/document-fork-deltas` deleted locally and on `origin`
- `fix/app-server-orphaned-thread-unload` deleted locally and on `origin`
- `perf/import-exploratory-stack` deleted locally after merge

PR state:

- PR #1 merged
- PR #3 merged
- PR #2 closed after its content was superseded by later direct `main` updates

Older `origin/*` branches still exist. They were not deleted in this pass because ownership and
intent are unclear. They should be handled via a dedicated branch-hygiene audit, not by blind
deletion.

## Architecture review

### 1. No global memory budget

The current architecture still treats loaded-thread state as effectively unbounded. Fixing specific
leaks helps, but the fork still lacks a top-level policy for:

- maximum loaded threads
- maximum retained inactive thread memory
- what to evict under pressure

Fork-specific opportunity:

- add a configurable loaded-thread budget with LRU or idle eviction for non-visible threads

### 2. History hydration is still too eager

The fork now carries streamed rollout parsing and live-parent fork snapshots, but the overall model
is still history-heavy:

- resume/fork paths still rehydrate substantial thread state eagerly
- many operations still assume large in-memory transcript availability

Fork-specific opportunity:

- move toward windowed history hydration and on-demand expansion

### 3. Compatibility tax is still too high

The fork now has typed-notification plumbing, but the broader architecture is still burdened by
compatibility-first design:

- old and new delivery paths coexist
- app-server still spends too much effort on transitional wire behavior

Fork-specific opportunity:

- make typed notifications the default path for fork-owned clients
- reduce or remove legacy event work where the fork no longer needs it

### 4. Renderer and GPU work remain under-constrained

The Rust-side fixes address real backend overhead, but they do not impose hard constraints on the
desktop renderer:

- transcript rendering can still be too eager
- heavy live updates can still flood the frontend
- GPU helper growth remains a likely freeze amplifier

Fork-specific opportunity:

- add renderer-side virtualization, throttling, and explicit GPU/heap measurement

### 5. No dedicated performance CI

The fork has evidence and docs, but not yet an automated performance gate:

- there is no repeatable benchmark recorded in CI
- there is no automatic regression detection for memory growth or spawn latency

Fork-specific opportunity:

- create a repeatable subagent stress benchmark and track before/after results in repo

## Highest-value next changes

If the goal is “make the desktop app stop degrading under real use,” the next high-value fork work
is:

1. loaded-thread budget and eviction policy
2. typed-notification default path for fork clients
3. renderer and GPU instrumentation plus transcript virtualization
4. reproducible stress benchmark and regression reporting

## What not to do

- do not keep importing large exploratory stacks without measurement
- do not delete old origin branches without proving they are safe to remove
- do not optimize for upstream acceptability over local usability

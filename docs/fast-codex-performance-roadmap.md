# Fast Codex Performance Roadmap

This document defines the performance strategy for `agustif/fast-codex` from first principles.

It is intentionally fork-oriented: the goal is not to minimize diff against upstream at all costs,
but to keep a small, disciplined downstream patch stack that directly improves the desktop and local
agent experience.

## Goals

The fork should optimize for:

- bounded memory growth during long-lived sessions
- near-constant-cost subagent spawning
- graceful degradation under load instead of machine-wide freeze
- reproducible before/after measurement for every performance patch
- low fork entropy: small deltas, documented rationale, and easy rollback

## Non-goals

- preserving upstream implementation details when they directly conflict with performance
- carrying speculative refactors that do not have measurement or a clear rollback path
- chasing upstream reviewability as the primary design constraint

## First-principles model

The performance model for a coding agent desktop app should follow these rules:

1. Persisted history is the source of truth.
   - Full transcripts belong on disk or in structured storage.
   - RAM should hold a bounded working set, not the entire past by default.

2. Live threads must be budgeted.
   - Every loaded thread has a memory cost.
   - Zero-subscriber threads must be aggressively reclaimable.
   - Background state should never survive indefinitely by accident.

3. Subagent cost must be weakly dependent on parent session size.
   - Child creation should use compact snapshots.
   - It should not replay or rebuild full parent history unless explicitly necessary.

4. One event should be serialized once.
   - Duplicate wire paths are allowed only when compatibility genuinely requires them.
   - Compatibility tax should be explicit, measurable, and removable.

5. The renderer is a view, not an archive.
   - Transcript rendering should be windowed and incremental.
   - Expensive UI surfaces should not hydrate or repaint eagerly.

6. Every expensive path needs a budget.
   - loaded-thread count
   - per-thread memory
   - subagent spawn latency
   - event throughput
   - renderer heap size
   - GPU helper footprint

## Current adopted deltas

The fork already carries these performance-relevant changes:

- orphaned-thread teardown after unexpected disconnect
- stale `ShutdownComplete` reconciliation
- streamed rollout parsing
- in-memory fork snapshots for live-parent `fork_context=true`
- typed-notification fast path plumbing
- lazy `FileWatcher`
- lower-cost DB log defaults and queue-full short-circuiting
- startup config preload reduction

These reduce real overhead, but they are not enough by themselves to guarantee stability under very
heavy desktop workloads.

## Remaining bottleneck classes

### 1. Session-size-scaled history work

Symptoms:

- subagent fan-out gets slower as conversations get longer
- resume/fork paths still materialize more history than they should

Why it matters:

- this is the strongest backend amplifier for long-lived sessions
- it turns “normal use over time” into a cost multiplier

Next actions:

- introduce a bounded fork snapshot representation
- audit all resume/fork paths for full-history materialization
- make transcript hydration incremental where possible

### 2. Event duplication and fanout pressure

Symptoms:

- app-server work scales with `events x subscribers`
- generic and typed notifications can overlap

Why it matters:

- this taxes both backend CPU and frontend update load
- it becomes expensive during high-rate tool output and subagent-heavy sessions

Next actions:

- move real clients onto typed-only notifications by default inside the fork
- remove legacy event serialization where the client no longer needs it
- add event-rate and event-size metrics

### 3. Renderer and GPU pressure

Symptoms:

- renderer RSS and GPU helper footprint can stay very high even when backend work is reduced
- live profiling suggests V8/module/code-cache and graphics buffer pressure

Why it matters:

- the desktop app can still freeze even if backend memory is improved
- once macOS enters compression and swap thrash, usability collapses quickly

Next actions:

- virtualize transcript and history rendering
- throttle or coalesce non-critical UI updates
- audit image, diff, and reasoning-output surfaces for retained graphics resources
- add renderer/GPU measurement to every desktop stress run

### 4. Loaded-thread lifecycle policy

Symptoms:

- multiple live threads or subagents can accumulate expensive state

Why it matters:

- even correct cleanup is not enough if the allowed live state is effectively unbounded

Next actions:

- add a loaded-thread budget
- introduce LRU or idle eviction for non-visible, non-subscribed threads
- define explicit policy for background subagent retention

### 5. Startup and idle tax

Symptoms:

- startup work still eagerly constructs some heavyweight subsystems

Why it matters:

- idle overhead reduces the headroom available before pressure begins

Next actions:

- continue lazifying manager creation where contract allows it
- keep startup profiles split into “boot required” vs “first use”

## Measurement discipline

Every performance patch should ship with:

- workload definition
  - example: two six-agent fan-out waves from a warm desktop session
- before/after app-server RSS
- before/after renderer RSS
- before/after GPU helper footprint when relevant
- before/after spawn latency for the target workflow
- rollback note explaining how to disable or revert the change

Preferred evidence sources:

- crate tests for correctness
- `/usr/bin/sample`
- `vmmap`
- generated flamegraphs
- saved benchmark notes in repo docs

## Patch train strategy

Future performance work should land as a sequence of small fork PRs:

1. measurement harness improvements
2. history/fork cost reductions
3. event-path reductions
4. loaded-thread budget and eviction policy
5. renderer-focused desktop optimizations

Each PR should answer:

- what bottleneck it targets
- how it was measured
- what user-facing behavior, if any, changes
- how to revert it

## Decision rule for new fork deltas

Carry a fork-only performance delta only if at least one of the following is true:

- it fixes a reproducible local usability failure
- it measurably reduces a hot path under a defined workload
- upstream is unlikely to take or prioritize it in the near term

If a delta does not meet one of those bars, it should stay out of `main`.

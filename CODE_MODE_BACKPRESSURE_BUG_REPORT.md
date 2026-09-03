# Code Mode bounded-queue saturation disconnects healthy sessions

Report date: 2026-09-03

## Summary

Codex Code Mode treats temporary bounded-channel saturation as a fatal transport failure.

Bursty parallel tool traffic can fill a healthy queue before its consumer drains it. The producer uses `try_send`, interprets `Full` as unavailable, and disconnects the session.

The observed error is:

```text
code-mode host outgoing queue is full
```

The failure invalidates running or yielded execution cells. A replacement host then exposes generation-prefixed identifiers such as `g3:1` and `g4:1`.

## Affected versions

The failure was reproduced with `codex-cli 0.147.0`.

The faulty paths remain present in:

- Latest stable tag `rust-v0.153.0`.
- Upstream `main` commit `728cb12fe5794b0c3a8e776fb4994b1650b973a8`.

## Environment

| Field | Value |
|---|---|
| Subscription | `self_serve_business_prolite` |
| Model | `gpt-5.6-sol` |
| Platform | `Darwin 25.6.0 arm64 arm` |
| macOS | `26.6`, build `25G5057c` |
| Terminal | Ghostty `1.3.1` |
| Affected thread | `01a057e7-b7fb-7db3-a5f2-c2929a43c8a6` |

The affected CLI session was not intentionally launched through `tmux`, `screen`, or `zellij`.

## Observed evidence

The exact error occurred repeatedly during a long-running research session with parallel subagents.

Recorded UTC occurrences included:

```text
2026-08-31T20:24:41.559Z
2026-08-31T20:25:24.581Z
2026-08-31T20:27:42.705Z
2026-08-31T20:33:02.683Z
2026-08-31T20:39:52.309Z
2026-08-31T21:01:23.796Z
```

Numeric execution-cell identifiers were replaced by generation-prefixed identifiers after failures. This is consistent with Code Mode host replacement and connection-generation advancement.

## Root cause

The stdio transport uses bounded Tokio MPSC channels, but both directions use non-blocking admission.

### Client to host

`codex-rs/code-mode/src/remote_session/connection/driver.rs` calls `outgoing_tx.try_send(frame)`.

`TrySendError::Full` invokes `fail("code-mode host outgoing queue is full")`. This marks the driver dead and cancels the connection.

### Host to client

`codex-rs/code-mode-host/src/peer.rs` also calls `outgoing_tx.try_send(frame)`.

`TrySendError::Full` disconnects the peer and returns the same queue-full failure.

### Active-cell routing

Active-cell delivery uses `try_send` on another bounded queue. Temporary congestion becomes `code-mode cell message queue is unavailable` and disconnects the peer.

The queues are intentionally bounded. The defect is treating temporary fullness as equivalent to a closed consumer.

## Failure sequence

```text
parallel tool-result burst
  -> the 128-frame outgoing queue fills temporarily
  -> try_send returns Full
  -> Code Mode marks the healthy connection failed
  -> host teardown or replacement begins
  -> running and yielded cells become stale
```

Reducing concurrency lowers the trigger probability. It does not correct the transport contract.

## Patch

Patch commit: `5b222356f6cb1483e820ec34e622b8e503d83969`

The patch implements bounded, awaited FIFO backpressure across the stdio transport:

- Client-to-host sends await queue capacity.
- Host-to-client sends await queue capacity.
- Connection cancellation preempts a blocked client send.
- Delegate dispatch reserves capacity before acquiring registry state.
- Active-cell routing releases its route mutex before awaiting capacity.
- Full queues no longer imply broken connections.

The patch also aligns host admission with the supported agent ceiling:

```text
MAX_ACTIVE_CELLS:       128 -> 512
MAX_IN_FLIGHT_REQUESTS: 256 -> 1024
```

One active agent can hold both an execute request and a wait request:

```text
MAX_IN_FLIGHT_REQUESTS = 2 * MAX_ACTIVE_CELLS
                       = 2 * 512
                       = 1024
```

The newer gRPC transport was audited and remains unchanged. Its event admission already uses bounded, cancellation-aware behavior.

## Deterministic regression coverage

The patch adds tests for the transport contract:

- A capacity-one client queue waits without disconnecting.
- A capacity-one host queue waits without disconnecting.
- Both paths preserve FIFO ordering after capacity becomes available.
- Connection cancellation terminates a blocked client send.
- Host disconnect terminates a blocked host writer.
- A 512-frame burst completes without loss or reordering.
- The host admits 512 active cells and rejects the 513th cleanly.
- Delegate admission failure returns an error without disconnecting.

## Validation on current upstream main

Base commit:

```text
728cb12fe5794b0c3a8e776fb4994b1650b973a8
```

Validation results:

```text
cargo test -p codex-code-mode-host --lib
37 passed; 0 failed

cargo test -p codex-code-mode --lib
71 passed; 0 failed

just fix -p codex-code-mode-host
passed

just fix -p codex-code-mode
passed

git diff --check
passed
```

The Rusty V8 `v150.4.0` Deno release lacks Codex's sandbox-enabled macOS arm64 artifact. Tests therefore used OpenAI's checksum-verified release artifacts.

That independent source-build problem is already tracked by `openai/codex#36698`.

## Reproduction

### Product-level reproduction

1. Enable Code Mode in Codex CLI.
2. Start a long-running session with many parallel agents.
3. Have agents issue overlapping `functions.exec` calls that produce bursty results.
4. Keep several executions yielded while new commands and delegate responses arrive.
5. Observe `code-mode host outgoing queue is full` when the 128-frame channel saturates.
6. Observe new generation-prefixed cell identifiers after host replacement.

### Deterministic unit-level reproduction

Use a bounded channel with capacity one. Fill it, then attempt a second `try_send` before receiving the first frame.

```rust
let (tx, _rx) = tokio::sync::mpsc::channel(1);

tx.try_send(1_u8).unwrap();
assert!(matches!(
    tx.try_send(2_u8),
    Err(tokio::sync::mpsc::error::TrySendError::Full(_))
));
```

The existing implementation converts this normal `Full` state into a fatal connection failure.

The patched behavior keeps the second send pending until the receiver releases capacity.

## Expected behavior

Temporary queue saturation should apply bounded backpressure. It should not drop frames, reorder frames, or invalidate unrelated execution cells.

A genuinely closed channel should still terminate the connection. Cancellation should remain able to preempt blocked sends.

## Related issues

- `openai/codex#33190` and `#42106` report active-cell admission exhaustion.
- `openai/codex#19608` concerns an app-server outbound queue, not Code Mode stdio IPC.
- `openai/codex#36698` tracks the separate Rusty V8 source-build failure.

No searched issue contained the exact `code-mode host outgoing queue is full` failure or this `try_send(Full)` root cause.

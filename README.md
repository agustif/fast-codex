<p align="center"><code>npm i -g @openai/codex</code><br />or <code>brew install --cask codex</code></p>
<p align="center"><strong>Codex CLI</strong> is a coding agent from OpenAI that runs locally on your computer.
<p align="center">
  <img src="https://github.com/openai/codex/blob/main/.github/codex-cli-splash.png" alt="Codex CLI splash" width="80%" />
</p>
</br>
If you want Codex in your code editor (VS Code, Cursor, Windsurf), <a href="https://developers.openai.com/codex/ide">install in your IDE.</a>
</br>If you want the desktop app experience, run <code>codex app</code> or visit <a href="https://chatgpt.com/codex?app-landing-page=true">the Codex App page</a>.
</br>If you are looking for the <em>cloud-based agent</em> from OpenAI, <strong>Codex Web</strong>, go to <a href="https://chatgpt.com/codex">chatgpt.com/codex</a>.</p>

---

## Quickstart

### Installing and running Codex CLI

Install globally with your preferred package manager:

```shell
# Install using npm
npm install -g @openai/codex
```

```shell
# Install using Homebrew
brew install --cask codex
```

Then simply run `codex` to get started.

<details>
<summary>You can also go to the <a href="https://github.com/openai/codex/releases/latest">latest GitHub Release</a> and download the appropriate binary for your platform.</summary>

Each GitHub Release contains many executables, but in practice, you likely want one of these:

- macOS
  - Apple Silicon/arm64: `codex-aarch64-apple-darwin.tar.gz`
  - x86_64 (older Mac hardware): `codex-x86_64-apple-darwin.tar.gz`
- Linux
  - x86_64: `codex-x86_64-unknown-linux-musl.tar.gz`
  - arm64: `codex-aarch64-unknown-linux-musl.tar.gz`

Each archive contains a single entry with the platform baked into the name (e.g., `codex-x86_64-unknown-linux-musl`), so you likely want to rename it to `codex` after extracting it.

</details>

### Using Codex with your ChatGPT plan

Run `codex` and select **Sign in with ChatGPT**. We recommend signing into your ChatGPT account to use Codex as part of your Plus, Pro, Team, Edu, or Enterprise plan. [Learn more about what's included in your ChatGPT plan](https://help.openai.com/en/articles/11369540-codex-in-chatgpt).

You can also use Codex with an API key, but this requires [additional setup](https://developers.openai.com/codex/auth#sign-in-with-an-api-key).

## Docs

- [**Codex Documentation**](https://developers.openai.com/codex)
- [**Contributing**](./docs/contributing.md)
- [**Installing & building**](./docs/install.md)
- [**Open source fund**](./docs/open-source-fund.md)
- [**Fast Codex Fork Ledger**](./docs/fast-codex-fork.md)
- [**Fast Codex Performance Roadmap**](./docs/fast-codex-performance-roadmap.md)
- [**Fast Codex Review (2026-03-10)**](./docs/fast-codex-review-2026-03-10.md)

## Fast Codex Fork Notes

`agustif/fast-codex` is a maintenance fork of [`openai/codex`](https://github.com/openai/codex).
The fork policy is simple:

- `main` should stay as close to `upstream/main` as possible
- fork-specific housekeeping on `main` must stay small and documented here
- candidate product or bugfix deltas should live on short-lived branches until they are either merged into this fork or dropped
- upstream is treated as a vendor source, not as an expected code-review path for this fork

### Main branch deltas

The full fork ledger lives in [docs/fast-codex-fork.md](./docs/fast-codex-fork.md).

The major deltas currently carried on fork `main` are:

| Delta | Purpose |
| --- | --- |
| `scripts/sync-upstream.sh` | Fetch `upstream/main`, sync the fork's `main` branch safely, optionally push it, and print the remaining local delta branches. |
| This README section | Keep a human-readable ledger of fork policy, branch deltas, and upstreaming status. |
| Disconnect-driven orphaned-thread cleanup in `codex-rs/app-server` | Prevent zero-subscriber threads from staying loaded after unexpected disconnects and reconcile late `ShutdownComplete` bookkeeping. |
| Typed notification fast path | Allow clients to opt out of legacy `codex/event/*` notifications and reduce duplicate event-delivery work. |
| Subagent fork and rollout optimizations | Reduce parent-history replay cost by using in-memory fork snapshots and streamed rollout parsing. |
| Startup and logging reductions | Lazy file watching, cheaper app-server startup preload, and lower-cost DB-backed logging defaults. |

### Active non-main deltas

There are currently no fork-owned code deltas intentionally kept off `main`.

Historical note:

- the orphaned-thread fix was reported upstream in [openai/codex#14137](https://github.com/openai/codex/issues/14137)
- upstream explicitly said they no longer generally accept external PRs and may not prioritize this bug soon
- this fork therefore carries its performance fixes on `main` directly

### Upstream sync workflow

From the repo root:

```shell
./scripts/sync-upstream.sh
```

Dry run without pushing:

```shell
./scripts/sync-upstream.sh --dry-run --no-push
```

The sync helper:

- refuses to run on a dirty worktree
- fast-forwards `main` when there are no fork-only commits on top of upstream
- merges `upstream/main` into `main` when fork-only commits already exist on `main`
- prints the currently active local delta branches after syncing

This repository is licensed under the [Apache-2.0 License](LICENSE).

#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/sync-upstream.sh [options]

Sync the fork's target branch with the upstream branch and optionally push it.

Options:
  --origin <remote>          Fork remote to push to. Default: origin
  --upstream <remote>        Upstream remote to fetch from. Default: upstream
  --target-branch <branch>   Branch to sync locally. Default: main
  --upstream-branch <branch> Upstream branch to merge from. Default: main
  --no-push                  Do not push the synced branch
  --dry-run                  Show the actions without mutating git state
  -h, --help                 Show this help text
EOF
}

origin_remote="origin"
upstream_remote="upstream"
target_branch="main"
upstream_branch="main"
push_changes=1
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin)
      origin_remote="$2"
      shift 2
      ;;
    --upstream)
      upstream_remote="$2"
      shift 2
      ;;
    --target-branch)
      target_branch="$2"
      shift 2
      ;;
    --upstream-branch)
      upstream_branch="$2"
      shift 2
      ;;
    --no-push)
      push_changes=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf 'DRY RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

if [[ -n "$(git -C "$repo_root" status --short)" ]]; then
  echo "Refusing to sync with a dirty worktree. Commit or stash changes first." >&2
  exit 1
fi

if ! git -C "$repo_root" remote get-url "$origin_remote" >/dev/null 2>&1; then
  echo "Missing origin remote: $origin_remote" >&2
  exit 1
fi

if ! git -C "$repo_root" remote get-url "$upstream_remote" >/dev/null 2>&1; then
  echo "Missing upstream remote: $upstream_remote" >&2
  exit 1
fi

restore_branch() {
  if [[ "$current_branch" != "$target_branch" ]]; then
    run git -C "$repo_root" checkout "$current_branch"
  fi
}

trap restore_branch EXIT

run git -C "$repo_root" fetch "$origin_remote" "$target_branch"
run git -C "$repo_root" fetch "$upstream_remote" "$upstream_branch"

if [[ "$current_branch" != "$target_branch" ]]; then
  run git -C "$repo_root" checkout "$target_branch"
fi

read -r ahead_count behind_count < <(
  git -C "$repo_root" rev-list --left-right --count \
    "$target_branch...$upstream_remote/$upstream_branch"
)

if [[ "$ahead_count" -eq 0 && "$behind_count" -eq 0 ]]; then
  echo "$target_branch is already in sync with $upstream_remote/$upstream_branch"
else
  if [[ "$behind_count" -gt 0 ]]; then
    if [[ "$ahead_count" -eq 0 ]]; then
      run git -C "$repo_root" merge --ff-only "$upstream_remote/$upstream_branch"
    else
      run git -C "$repo_root" merge --no-edit "$upstream_remote/$upstream_branch"
    fi
  else
    echo "$target_branch already contains all commits from $upstream_remote/$upstream_branch"
  fi
fi

if [[ "$push_changes" -eq 1 ]]; then
  run git -C "$repo_root" push "$origin_remote" "$target_branch"
fi

echo
echo "Active delta branches relative to $target_branch:"

delta_found=0
while IFS= read -r branch; do
  if [[ "$branch" == "$target_branch" ]]; then
    continue
  fi
  if git -C "$repo_root" merge-base --is-ancestor "$branch" "$target_branch"; then
    continue
  fi
  delta_found=1
  commits_ahead="$(
    git -C "$repo_root" rev-list --count "$target_branch..$branch"
  )"
  printf '  - %s (%s commit%s ahead)\n' \
    "$branch" \
    "$commits_ahead" \
    "$([[ "$commits_ahead" -eq 1 ]] && echo "" || echo "s")"
done < <(git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads)

if [[ "$delta_found" -eq 0 ]]; then
  echo "  - none"
fi

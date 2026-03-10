#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-fast-codex.sh [options]

Build the current fast-codex checkout, install it as `fast-codex`, and add an
interactive-shell alias `fc` that points to the installed binary.

Options:
  --install-dir <dir>  Target binary directory. Default: $HOME/.local/bin
  --profile <file>     Shell profile to update. Default: auto-detect from $SHELL
  --skip-build         Reuse an existing release binary instead of rebuilding
  -h, --help           Show this help text
EOF
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cargo_workspace="$repo_root/codex-rs"
install_dir="${FAST_CODEX_INSTALL_DIR:-$HOME/.local/bin}"
profile="${FAST_CODEX_PROFILE:-}"
skip_build=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      install_dir="$2"
      shift 2
      ;;
    --profile)
      profile="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
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

step() {
  printf '==> %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required for fast-codex installation." >&2
    exit 1
  fi
}

detect_profile() {
  if [[ -n "$profile" ]]; then
    printf '%s\n' "$profile"
    return
  fi

  case "${SHELL:-}" in
    */zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    */bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

ensure_path_line() {
  local resolved_profile="$1"
  local path_line="export PATH=\"$install_dir:\$PATH\""

  mkdir -p "$(dirname "$resolved_profile")"
  touch "$resolved_profile"

  if ! grep -F "$path_line" "$resolved_profile" >/dev/null 2>&1; then
    {
      printf '\n# Added by fast-codex installer\n'
      printf '%s\n' "$path_line"
    } >>"$resolved_profile"
  fi
}

write_alias_block() {
  local resolved_profile="$1"
  local alias_target="$install_dir/fast-codex"
  local begin_marker="# >>> fast-codex alias >>>"
  local end_marker="# <<< fast-codex alias <<<"
  local tmp

  mkdir -p "$(dirname "$resolved_profile")"
  touch "$resolved_profile"
  tmp="$(mktemp)"

  python3 - "$resolved_profile" "$tmp" "$begin_marker" "$end_marker" <<'PY'
import pathlib
import sys

profile = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
begin = sys.argv[3]
end = sys.argv[4]

lines = profile.read_text().splitlines()
out = []
inside = False
for line in lines:
    if line == begin:
        inside = True
        continue
    if line == end:
        inside = False
        continue
    if not inside:
        out.append(line)

tmp.write_text("\n".join(out) + ("\n" if out else ""))
PY

  mv "$tmp" "$resolved_profile"

  {
    printf '\n%s\n' "$begin_marker"
    printf '# `fc` is a shell builtin, so PATH alone cannot override it reliably.\n'
    printf 'alias fc=%q\n' "$alias_target"
    printf '%s\n' "$end_marker"
  } >>"$resolved_profile"
}

require_command cargo
require_command python3

binary_path="$cargo_workspace/target/release/codex"

if [[ "$skip_build" -eq 0 ]]; then
  step "Building fast-codex release binary"
  cargo build --release --bin codex --manifest-path "$cargo_workspace/Cargo.toml"
elif [[ ! -x "$binary_path" ]]; then
  echo "Release binary not found at $binary_path. Re-run without --skip-build." >&2
  exit 1
fi

resolved_profile="$(detect_profile)"

step "Installing fast-codex into $install_dir"
mkdir -p "$install_dir"
install -m 755 "$binary_path" "$install_dir/fast-codex"

step "Ensuring $install_dir is on PATH via $resolved_profile"
ensure_path_line "$resolved_profile"

step "Installing interactive shell alias fc via $resolved_profile"
write_alias_block "$resolved_profile"

step "Installation complete"
printf 'Installed binary: %s\n' "$install_dir/fast-codex"
printf 'Shell profile updated: %s\n' "$resolved_profile"
printf 'Open a new shell or run: source %q\n' "$resolved_profile"
printf 'Then run: fast-codex --help\n'
printf 'Or use the interactive alias: fc --help\n'

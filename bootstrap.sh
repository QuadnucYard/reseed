#!/bin/sh
set -eu

state_repository=""
state_root=""
profiles="personal"
no_restore=0
dry_run=0
offline=0
script_dir=""

# Print the command-line usage.
usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--state-repository URL] [--state-root PATH]
                    [--profiles NAMES] [--no-restore] [--offline] [--dry-run]
EOF
}

# Parse command-line arguments into the global option variables.
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-repository|--repository) state_repository=$2; shift 2 ;;
      --state-root) state_root=$2; shift 2 ;;
      --profiles) profiles=$2; shift 2 ;;
      --no-restore) no_restore=1; shift ;;
      --offline) offline=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# Redact the userinfo of a URL so credentials never leak into errors.
scrub_url() {
  printf '%s\n' "$1" | sed -E 's#([a-z][a-z0-9+.-]*://)[^@/]+@#\1***@#g'
}

# Prepend portable bootstrap tools (tools/macos-<arch>) to PATH when the
# directory ships beside this script. Prepending shadows any duplicate tools
# already on PATH so the bundle's pinned versions win.
resolve_tools() {
  arch=$(uname -m)
  if [ -n "$script_dir" ] && [ -d "$script_dir/tools/macos-$arch" ]; then
    PATH="$script_dir/tools/macos-$arch:$PATH"
    export PATH
    printf '%s\n' "reseed: using portable tools from $script_dir/tools/macos-$arch"
  fi
}

# In offline mode every bootstrap-contract tool must already be available.
ensure_offline_tools() {
  if [ -n "$state_repository" ]; then
    echo "--offline cannot be combined with --state-repository; use an extracted bundle state directory" >&2
    exit 2
  fi
  for command_name in git chezmoi nu; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Offline recovery requires $command_name in tools/macos-$arch or on PATH" >&2
      exit 1
    fi
  done
}

# Install Homebrew when absent, then the bootstrap-contract tools.
install_bootstrap_tools() {
  if ! command -v brew >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to install Homebrew" >&2
      exit 1
    fi
    printf '%s\n' "reseed: installing Homebrew"
    # Pinned installer revision for supply-chain stability; the commit is
    # signed by Homebrew. Bump deliberately after review; current SHA:
    # https://github.com/Homebrew/install/commit/24173182915f24bdd52a22fd073e421953b2a252
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/24173182915f24bdd52a22fd073e421953b2a252/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  printf '%s\n' "reseed: ensuring bootstrap tools"
  brew install git chezmoi nushell mise
}

# Resolve the private state root from --state-root, RESEED_STATE_ROOT, or the
# default under the home directory.
resolve_state_root() {
  if [ -n "$state_root" ]; then
    case "$state_root" in
      /*) ;;
      # A relative --state-root is anchored at the current directory.
      *) state_root=$(pwd)/$state_root ;;
    esac
  elif [ -n "${RESEED_STATE_ROOT:-}" ]; then
    state_root=$RESEED_STATE_ROOT
  else
    state_root=$HOME/.local/share/reseed
  fi
}

# Clone the private state repository when the state root is uninitialized.
# Refuses a nonempty directory without the .reseed-state sentinel, reads the
# remote before cloning so a wrong URL fails early, and only clones when the
# remote has a main branch.
ensure_state_repository() {
  sentinel=$state_root/.reseed-state
  if [ -z "$state_repository" ] || [ -f "$sentinel" ]; then
    return
  fi
  if [ -d "$state_root" ] && [ -n "$(ls -A "$state_root")" ]; then
    echo "Refusing nonempty state directory without .reseed-state: $state_root" >&2
    exit 1
  fi
  if ! refs=$(git ls-remote "$state_repository"); then
    echo "Cannot read the private state repository: $(scrub_url "$state_repository")" >&2
    exit 1
  fi
  if printf '%s\n' "$refs" | grep -q 'refs/heads/main$'; then
    printf '%s\n' "reseed: cloning private state"
    git clone --branch main --single-branch "$state_repository" "$state_root"
  elif [ -n "$refs" ]; then
    echo "The private state repository has content but no main branch." >&2
    exit 1
  fi
}

# Run "nu init" to create or validate the private state, wiring up the remote
# URL when one was given.
initialize_state() {
  sentinel=$state_root/.reseed-state
  if [ ! -f "$sentinel" ]; then
    if [ -n "$state_repository" ]; then
      nu "$entrypoint" init --state-root "$state_root" --remote-url "$state_repository"
    else
      nu "$entrypoint" init --state-root "$state_root"
    fi
  elif [ -n "$state_repository" ]; then
    nu "$entrypoint" init --state-root "$state_root" --remote-url "$state_repository"
  fi
}

# Run the restore (or report how to plan it) once the state is ready.
run_restore() {
  printf '%s\n' "reseed: engine: $script_dir"
  printf '%s\n' "reseed: private state: $state_root"
  if [ "$no_restore" -eq 1 ]; then
    printf '%s\n' "reseed: bootstrap completed; run: nu '$entrypoint' plan --state-root '$state_root' --profiles '$profiles'"
  elif [ "$dry_run" -eq 1 ]; then
    if [ "$offline" -eq 1 ]; then
      nu "$entrypoint" restore --state-root "$state_root" --profiles "$profiles" --dry-run --skip-software
    else
      nu "$entrypoint" restore --state-root "$state_root" --profiles "$profiles" --dry-run
    fi
  elif [ "$offline" -eq 1 ]; then
    nu "$entrypoint" restore --state-root "$state_root" --profiles "$profiles" --skip-software
  else
    nu "$entrypoint" restore --state-root "$state_root" --profiles "$profiles"
  fi
}

parse_args "$@"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
resolve_tools
if [ "$offline" -eq 1 ]; then
  ensure_offline_tools
else
  install_bootstrap_tools
fi

if [ -z "$script_dir" ] || [ ! -f "$script_dir/reseed.nu" ]; then
  echo "Run bootstrap.sh from the Reseed engine directory." >&2
  exit 1
fi
entrypoint=$script_dir/reseed.nu

resolve_state_root
ensure_state_repository
initialize_state
run_restore

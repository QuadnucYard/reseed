#!/bin/sh
set -eu

state_repository=""
state_source=""
state_root=""
profiles="personal"
no_restore=0
dry_run=0
offline=0
update_tools=0
no_update_tools=0
brew_install_url=""
homebrew_mirror=""
script_dir=""

# Homebrew installer script served by the USTC mirror (daily sync, HEAD
# only; the pinned official commit is used unless a mirror is requested).
ustc_install_url="https://mirrors.ustc.edu.cn/misc/brew-install.sh"

# Print the command-line usage.
usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--state-repository URL] [--state-source PATH] [--state-root PATH]
                    [--profiles NAMES] [--no-restore] [--offline] [--dry-run]
                    [--update-tools] [--no-update-tools]
                    [--brew-install-url URL] [--homebrew-mirror ustc|tuna]

--state-source PATH      Import an immutable downloaded private-state source
                         (a Git checkout, bundle archive, or raw snapshot)
                         and restore from it. Mutually exclusive with
                         --state-repository.
--update-tools      Upgrade outdated bootstrap tools without prompting.
--no-update-tools   Skip the bootstrap-tool update check entirely.
--brew-install-url URL   Install Homebrew from a custom installer script.
--homebrew-mirror NAME   Use a China mirror for the installer and for the
                         bootstrap-tool installs (ustc or tuna; ustc also
                         switches the installer script).
EOF
}

# Parse command-line arguments into the global option variables.
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-repository|--repository) state_repository=$2; shift 2 ;;
      --state-source) state_source=$2; shift 2 ;;
      --state-root) state_root=$2; shift 2 ;;
      --profiles) profiles=$2; shift 2 ;;
      --no-restore) no_restore=1; shift ;;
      --offline) offline=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --update-tools) update_tools=1; shift ;;
      --no-update-tools) no_update_tools=1; shift ;;
      --brew-install-url) brew_install_url=$2; shift 2 ;;
      --homebrew-mirror) homebrew_mirror=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  if [ -n "$state_source" ] && [ -n "$state_repository" ]; then
    echo "--state-source and --state-repository are mutually exclusive" >&2
    exit 2
  fi
  if [ -n "$brew_install_url" ] && [ -n "$homebrew_mirror" ]; then
    echo "--brew-install-url and --homebrew-mirror are mutually exclusive" >&2
    exit 2
  fi
  case "$homebrew_mirror" in
    ""|ustc|tuna) ;;
    *) echo "Unsupported --homebrew-mirror: $homebrew_mirror (use ustc or tuna)" >&2; exit 2 ;;
  esac
  if [ "$update_tools" -eq 1 ] && [ "$no_update_tools" -eq 1 ]; then
    echo "--update-tools and --no-update-tools are mutually exclusive" >&2
    exit 2
  fi
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

# In offline mode every bootstrap-contract tool must already be available. A
# --state-source path is local and compatible with offline recovery; only a
# remote --state-repository is rejected.
ensure_offline_tools() {
  if [ -n "$state_repository" ]; then
    echo "--offline cannot be combined with --state-repository; use an extracted bundle state directory or --state-source" >&2
    exit 2
  fi
  for command_name in git chezmoi nu; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Offline recovery requires $command_name in tools/macos-$arch or on PATH" >&2
      exit 1
    fi
  done
}

# Run a command, killing it after the given number of seconds. Prefers GNU
# timeout, falls back to perl's alarm (preinstalled on macOS), and otherwise
# runs unwrapped so a missing tool never blocks the bootstrap.
run_with_timeout() {
  seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
  else
    "$@"
  fi
}

# Environment variables that route Homebrew itself, its core tap, and its
# bottles through the given China mirror. The values follow each mirror's
# published setup; setting them for the bootstrap keeps a first boot away
# from GitHub entirely.
mirror_environment() {
  case "$1" in
    ustc)
      export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
      export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
      export HOMEBREW_CASK_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-cask.git"
      export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
      export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
      ;;
    tuna)
      export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
      export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
      export HOMEBREW_CASK_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-cask.git"
      export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
      export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
      ;;
  esac
}

# Install Homebrew when absent, then the bootstrap-contract tools.
install_bootstrap_tools() {
  brew_preexisting=0
  # A requested mirror also routes the bootstrap-tool installs (and a brew
  # update run later) away from GitHub, even when brew already exists.
  if [ -n "$homebrew_mirror" ]; then
    mirror_environment "$homebrew_mirror"
  fi
  if ! command -v brew >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to install Homebrew" >&2
      exit 1
    fi
    if [ "$homebrew_mirror" = "ustc" ] && [ -z "$brew_install_url" ]; then
      brew_install_url=$ustc_install_url
    fi
    if [ -z "$brew_install_url" ]; then
      # Pinned installer revision for supply-chain stability; the commit is
      # signed by Homebrew. Bump deliberately after review; current SHA:
      # https://github.com/Homebrew/install/commit/24173182915f24bdd52a22fd073e421953b2a252
      brew_install_url="https://raw.githubusercontent.com/Homebrew/install/24173182915f24bdd52a22fd073e421953b2a252/install.sh"
    fi
    printf '%s\n' "reseed: downloading Homebrew installer ($brew_install_url)"
    # Bound the download so a blocked network fails fast instead of hanging.
    # --retry-all-errors needs curl >= 7.71; older macOS ships 7.64, which
    # still retries transient errors (timeouts and 5xx) with plain --retry.
    if curl --version 2>/dev/null | awk -F'[ .]' '/^curl / { if (($2 > 7) || ($2 == 7 && $3 >= 71)) exit 0; exit 1 }'; then
      retry_all_args="--retry-all-errors"
    else
      retry_all_args=""
    fi
    installer_script=$(curl --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 5 $retry_all_args -fsSL "$brew_install_url") || {
      echo "Failed to download the Homebrew installer (network timeout or blocked host):" >&2
      echo "  $brew_install_url" >&2
      echo "If GitHub is slow or unreachable, retry with a China mirror:" >&2
      echo "  ./bootstrap.sh --homebrew-mirror ustc" >&2
      echo "or point at a specific installer script (e.g. the USTC daily sync):" >&2
      echo "  ./bootstrap.sh --brew-install-url $ustc_install_url" >&2
      exit 1
    }
    # A captive portal or proxy error page can still return HTTP 200, so
    # refuse to execute anything that does not look like a shell script
    # (custom --brew-install-url scripts may use any shebang shell).
    case "$installer_script" in
      "#!"*) ;;
      *)
        echo "The downloaded content is not the Homebrew installer (intercepted or served a page instead):" >&2
        echo "  $brew_install_url" >&2
        echo "Retry with --homebrew-mirror ustc or a --brew-install-url you trust." >&2
        exit 1
        ;;
    esac
    # First attempt is non-interactive. When admin permission is required
    # (e.g. Intel Macs installing to /usr/local, or a missing Xcode Command
    # Line Tools prompt), it fails; then retry interactively so the user can
    # enter their administrator password.
    if ! NONINTERACTIVE=1 run_with_timeout 900 /bin/bash -c "$installer_script"; then
      echo "The non-interactive Homebrew install failed. Possible causes:" >&2
      echo "  - admin permission is required (Intel Macs install to /usr/local)" >&2
      echo "  - Xcode Command Line Tools are missing (run: xcode-select --install)" >&2
      if [ ! -t 0 ]; then
        echo "stdin is not a terminal, so the interactive password retry is skipped." >&2
        echo "Run bootstrap.sh from a terminal to allow the admin password prompt." >&2
        exit 1
      fi
      echo "Retrying interactively so you can enter your administrator password if prompted." >&2
      if ! run_with_timeout 900 /bin/bash -c "$installer_script"; then
        echo "Homebrew installation failed. Run 'xcode-select --install' if needed, then rerun bootstrap.sh." >&2
        exit 1
      fi
    fi
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    else
      echo "Homebrew reported success but the brew executable is missing." >&2
      echo "If it still needed an administrator password, rerun bootstrap.sh interactively." >&2
      exit 1
    fi
  else
    brew_preexisting=1
  fi

  printf '%s\n' "reseed: ensuring bootstrap tools"
  # The mirror environment (when requested) plus NO_AUTO_UPDATE keep this
  # step off GitHub and avoid a long surprise update on a fresh install.
  if ! HOMEBREW_NO_AUTO_UPDATE=1 run_with_timeout 1800 brew install git chezmoi nushell mise; then
    # The recovery-critical tools (the offline recovery trio) must exist for
    # the bootstrap to continue, so their install failure stops the script.
    # A missing software-only tool (mise) is only a warning: the restore's
    # verification stage reports it, and --skip-software does not need it.
    missing=""
    for command_name in git chezmoi nu; do
      if ! command -v "$command_name" >/dev/null 2>&1; then
        missing="$missing $command_name"
      fi
    done
    if [ -n "$missing" ]; then
      echo "Failed to install required bootstrap tools:$missing. Check the network;" >&2
      echo "if GitHub is blocked, rerun with --homebrew-mirror ustc." >&2
      exit 1
    fi
    if ! command -v mise >/dev/null 2>&1; then
      echo "reseed: mise could not be installed; continuing without it (software-only)." >&2
    fi
  fi

  if [ -n "$homebrew_mirror" ]; then
    printf '%s\n' "reseed: mirror ($homebrew_mirror) is active for this session only."
    printf '%s\n' "To keep it in every shell, add these lines to your profile, or run"
    printf '%s\n' "'reseed restore' which persists the mirrors from software.homebrew.env:"
    env | sed -n 's/^\(HOMEBREW_[A-Z0-9_]*\)=\(.*\)$/  export \1="\2"/p'
  fi
}

# Check the bootstrap-contract tools for available upgrades and let the user
# decide whether to apply them. Advisory: a failure only warns, and a fresh
# Homebrew install is already current so it is skipped.
check_tool_updates() {
  [ "$no_update_tools" -eq 1 ] && return
  [ "$brew_preexisting" -eq 1 ] || return
  printf '%s\n' "reseed: checking for outdated bootstrap tools"
  # Refresh the metadata, which also self-updates Homebrew itself; the mirror
  # environment (when requested) routes this away from GitHub as well.
  if ! update_output=$(run_with_timeout 900 brew update 2>&1); then
    echo "reseed: brew update failed; skipping the outdated check" >&2
    return
  fi
  if printf '%s\n' "$update_output" | grep -q "Updated Homebrew"; then
    printf '%s\n' "reseed: Homebrew itself was updated:"
    printf '%s\n' "$update_output" | grep "Updated Homebrew" | sed 's/^/  /'
  fi
  # Outdated lines are "name installed < available" (brew < 4.4) or
  # "name (installed: x) != y" (brew >= 4.4); only the leading name matters.
  outdated_tools=$(brew outdated --formula 2>/dev/null | awk '$1 == "git" || $1 == "chezmoi" || $1 == "nushell" || $1 == "mise"') || true
  if [ -z "$outdated_tools" ]; then
    printf '%s\n' "reseed: bootstrap tools are up to date"
    return
  fi
  printf '%s\n' "reseed: outdated bootstrap tools:"
  printf '%s\n' "$outdated_tools" | sed 's/^/  /'
  if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "reseed: dry run; leaving outdated tools unchanged"
    return
  fi
  if [ "$update_tools" -eq 1 ]; then
    :
  elif [ -t 0 ]; then
    printf '%s\n' "Upgrade these bootstrap tools now? [y/N] "
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) printf '%s\n' "reseed: skipping upgrade"; return ;;
    esac
  else
    printf '%s\n' "reseed: non-interactive run; leaving outdated tools unchanged"
    return
  fi
  upgrade_list=$(printf '%s\n' "$outdated_tools" | awk '{print $1}' | tr '\n' ' ')
  printf '%s\n' "reseed: upgrading: $upgrade_list"
  if ! HOMEBREW_NO_AUTO_UPDATE=1 run_with_timeout 1800 brew upgrade $upgrade_list; then
    echo "reseed: failed to upgrade the bootstrap tools; continuing with the installed versions" >&2
  fi
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

# Fast-forward the already-initialized private state from the provided
# repository, so recovery always restores from the supplied source. The sync
# logic lives in "nu sync-state": it refuses mismatched remotes, leaves a
# dirty or diverged working tree alone, and fails when the repository cannot
# be reached.
sync_state_repository() {
  printf '%s\n' "reseed: syncing private state: $(scrub_url "$state_repository")"
  nu "$entrypoint" sync-state --state-root "$state_root" --repository "$state_repository"
}

# Clone the private state repository when the state root is uninitialized.
# Refuses a nonempty directory without the .reseed-state sentinel, reads the
# remote before cloning so a wrong URL fails early, and clones the remote's
# default branch (from its symbolic HEAD) rather than assuming main. An
# already-initialized root is instead synced from the provided repository so a
# stale local copy repairs itself.
ensure_state_repository() {
  sentinel=$state_root/.reseed-state
  if [ -z "$state_repository" ]; then
    return
  fi
  if [ -f "$sentinel" ]; then
    sync_state_repository
    return
  fi
  if [ -d "$state_root" ] && [ -n "$(ls -A "$state_root")" ]; then
    echo "Refusing nonempty state directory without .reseed-state: $state_root" >&2
    exit 1
  fi
  if ! sym=$(git ls-remote --symref "$state_repository" HEAD 2>/dev/null); then
    echo "Cannot read the private state repository: $(scrub_url "$state_repository")" >&2
    exit 1
  fi
  default_branch=$(printf '%s\n' "$sym" | awk '/^ref:/ { sub(/^ref: refs\/heads\//, ""); print $1; exit }')
  default_branch=${default_branch:-main}
  if printf '%s\n' "$sym" | grep -q "refs/heads/$default_branch$"; then
    printf '%s\n' "reseed: cloning private state"
    git clone --branch "$default_branch" --single-branch "$state_repository" "$state_root"
  elif [ -n "$sym" ]; then
    echo "The private state repository has content but no $default_branch branch." >&2
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

# Run the restore (or report how to plan it) once the state is ready. When a
# --state-source was given, the restore command receives --state-source so the
# downloaded source is validated and imported atomically before the recovery
# plan runs. Arguments are built positionally so paths containing spaces are
# never split.
run_restore() {
  printf '%s\n' "reseed: engine: $script_dir"
  printf '%s\n' "reseed: private state: $state_root"
  if [ "$no_restore" -eq 1 ]; then
    printf '%s\n' "reseed: bootstrap completed; run: nu '$entrypoint' plan --state-root '$state_root' --profiles '$profiles'"
    return
  fi
  set -- "$entrypoint" restore --state-root "$state_root" --profiles "$profiles"
  if [ -n "$state_source" ]; then
    set -- "$@" --state-source "$state_source"
  fi
  if [ "$dry_run" -eq 1 ]; then
    set -- "$@" --dry-run
  fi
  if [ "$offline" -eq 1 ]; then
    set -- "$@" --skip-software
  fi
  nu "$@"
}

parse_args "$@"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
resolve_tools
if [ "$offline" -eq 1 ]; then
  ensure_offline_tools
else
  install_bootstrap_tools
  check_tool_updates
fi

if [ -z "$script_dir" ] || [ ! -f "$script_dir/reseed.nu" ]; then
  echo "Run bootstrap.sh from the Reseed engine directory." >&2
  exit 1
fi
entrypoint=$script_dir/reseed.nu

resolve_state_root
if [ -n "$state_source" ]; then
  # A downloaded source drives recovery directly: import it and restore.
  run_restore
else
  ensure_state_repository
  initialize_state
  run_restore
fi

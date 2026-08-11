# Private state repository operations (status, init, pull, commit) and the
# offline source bundle builder.

use core.nu [command-exists detect-os expand-home fail info run-command scrub-url state-sentinel-exists warning]

# Probe whether the private state root is a clean Git repository and, when it
# is, report the current branch.
export def git-status [
  root: path # Directory to probe.
]: nothing -> record {
  if not (command-exists git) {
    return {available: false repository: false clean: null branch: null}
  }
  let probe = (run-command git ["-C" ($root | into string) "rev-parse" "--is-inside-work-tree"] --allow-failure --quiet --capture)
  if $probe.exit_code != 0 {
    return {available: true repository: false clean: null branch: null}
  }
  let changes = (run-command git ["-C" ($root | into string) "status" "--porcelain"] --quiet --capture)
  let branch = (run-command git ["-C" ($root | into string) "branch" "--show-current"] --quiet --capture)
  {
    available: true
    repository: true
    clean: ($changes.stdout | str trim | is-empty)
    branch: ($branch.stdout | str trim)
  }
}

# Initialize the private state repository and configure its remote. Creates
# the branch from config.git.branch when missing and refuses to replace an
# existing remote that points elsewhere.
export def git-init [
  root: path # Private state root.
  config: record # Loaded configuration; git.branch and git.remote.
  --remote-url: string # Private remote URL to configure.
  --dry-run # Show Git commands without running them.
] {
  let status = (git-status $root)
  if not $status.available { fail "Git is required to initialize the Reseed source" }
  let branch = ($config.git.branch? | default main)
  let remote = ($config.git.remote? | default origin)
  if not $status.repository {
    run-command git ["-C" ($root | into string) "init" "-b" $branch] --dry-run=$dry_run | ignore
  } else {
    info $"Git repository already initialized: ($root)"
    # An unborn or detached HEAD has no current branch; switch to the
    # configured branch, creating it when it does not exist yet.
    if ($status.branch | str trim | is-empty) {
      let branch_ref = $"refs/heads/($branch)"
      let branch_exists = (run-command git ["-C" ($root | into string) "show-ref" "--verify" $branch_ref] --allow-failure --quiet --capture)
      let args = if $branch_exists.exit_code == 0 {
        ["-C" ($root | into string) "switch" $branch]
      } else {
        ["-C" ($root | into string) "switch" "-c" $branch]
      }
      run-command git $args --dry-run=$dry_run | ignore
    } else if $status.branch != $branch {
      fail $"Reseed is on Git branch '($status.branch)', but config.git.branch is '($branch)'"
    }
  }

  if ($remote_url != null) and not ($remote_url | str trim | is-empty) {
    if $dry_run and not $status.repository {
      run-command git ["-C" ($root | into string) "remote" "add" $remote $remote_url] --dry-run | ignore
    } else {
      let existing = (run-command git ["-C" ($root | into string) "remote" "get-url" $remote] --allow-failure --quiet --capture)
      if $existing.exit_code == 0 {
        let current = ($existing.stdout | str trim)
        if $current != $remote_url {
          fail $"Git remote '($remote)' already points to (scrub-url $current); refusing to replace it with (scrub-url $remote_url)"
        }
        info $"Git remote '($remote)' already configured: (scrub-url $current)"
      } else {
        run-command git ["-C" ($root | into string) "remote" "add" $remote $remote_url] --dry-run=$dry_run | ignore
      }
    }
  }
  info $"Reseed source repository: ($root)"
}

# Fail when the provided source is not a readable Git repository with a main
# branch, so a bad URL fails before it can pollute the configured origin.
def validate-source [
  repository: string # Private state repository URL.
] {
  let remote_refs = (run-command git ["ls-remote" $repository] --allow-failure --quiet --capture)
  if $remote_refs.exit_code != 0 {
    fail $"Cannot read the private state repository: (scrub-url $repository)"
  }
  if not ($remote_refs.stdout | lines | any {|line| $line | str ends-with "refs/heads/main" }) {
    fail $"The private state repository has no main branch: (scrub-url $repository)"
  }
}

# Add the provided repository as origin when the state was seeded without one.
def configure-origin [
  root: path # Private state root.
  repository: string # Private state repository URL.
  missing: bool # True when no origin remote is configured yet.
] {
  if $missing {
    run-command git ["-C" ($root | into string) "remote" "add" "origin" $repository] --quiet | ignore
  }
}

# Fetch the provided state and reset the working tree to it, replacing files
# the repository owns while keeping non-colliding untracked files.
def adopt-origin [
  root: path # Private state root.
] {
  run-command git ["-C" ($root | into string) "fetch" "origin" "main"] | ignore
  run-command git ["-C" ($root | into string) "reset" "--hard" "origin/main"] | ignore
}

# Fast-forward the already-initialized private state from the provided
# repository, so the platform bootstraps restore from the supplied source even
# when the state root was seeded or cloned earlier. Refuses to sync a local
# clone whose origin points at a different repository, validates that the
# provided source is a readable Git repository with a main branch before
# configuring it (so a bad source never pollutes origin), and leaves a dirty or
# diverged working tree untouched unless --replace explicitly discards local
# work. A local branch that is ahead of the remote (newer unpushed state) is
# kept and reported as such; --replace discards it too. A state root that is
# not yet a repository (or a template seed on an unborn branch) adopts the
# provided state wholesale, replacing its colliding files while keeping any
# non-colliding untracked files. Returns a record reporting whether the state
# was adopted or synced and, when skipped, why.
export def git-sync [
  root: path # Private state root.
  repository: string # Private state repository URL.
  --replace # Discard local commits and uncommitted changes in favor of the provided state.
]: nothing -> record {
  if not (command-exists git) { fail "Git is required to sync the private state" }
  let probe = (run-command git ["-C" ($root | into string) "rev-parse" "--is-inside-work-tree"] --allow-failure --quiet --capture)
  if $probe.exit_code != 0 {
    # The bootstrap only syncs a root that already carries the sentinel. When
    # that root was never initialized as a repository, initialize it and adopt
    # the provided state so its files are copied in and the root becomes
    # git-managed. git init touches no files; reset --hard replaces only files
    # the provided repository owns and keeps non-colliding untracked files.
    if (state-sentinel-exists $root) {
      validate-source $repository
      run-command git ["-C" ($root | into string) "init" "-b" "main"] | ignore
      run-command git ["-C" ($root | into string) "remote" "add" "origin" $repository] --quiet | ignore
      adopt-origin $root
      info $"Initialized and adopted the provided private state: (scrub-url $repository)"
      return {synced: true status: "adopted"}
    }
    warning "Private state is not a Git repository; leaving it unchanged"
    return {synced: false status: "no-repo"}
  }
  let existing = (run-command git ["-C" ($root | into string) "remote" "get-url" "origin"] --allow-failure --quiet --capture)
  let origin_missing = ($existing.exit_code != 0)
  if not $origin_missing {
    let current = ($existing.stdout | str trim)
    if $current != $repository {
      fail $"Git remote 'origin' already points to (scrub-url $current); refusing to sync from (scrub-url $repository)"
    }
  }
  let unborn = (run-command git ["-C" ($root | into string) "rev-parse" "--verify" "HEAD"] --allow-failure --quiet --capture)
  if $unborn.exit_code != 0 {
    validate-source $repository
    configure-origin $root $repository $origin_missing
    adopt-origin $root
    info $"Adopted the provided private state over the uncommitted local seed: (scrub-url $repository)"
    return {synced: true status: "adopted"}
  }
  let dirty = (run-command git ["-C" ($root | into string) "status" "--porcelain"] --quiet --capture)
  if not ($dirty.stdout | str trim | is-empty) {
    if $replace {
      validate-source $repository
      configure-origin $root $repository $origin_missing
      adopt-origin $root
      warning "Discarded local private-state changes in favor of the provided state"
      return {synced: true status: "replaced"}
    }
    warning "Private state has local changes; leaving it unchanged"
    return {synced: false status: "dirty"}
  }
  validate-source $repository
  configure-origin $root $repository $origin_missing
  let pulled = (run-command git ["-C" ($root | into string) "pull" "--ff-only" "origin" "main"] --allow-failure --quiet --capture)
  if $pulled.exit_code != 0 {
    if ($pulled.stderr | str contains "fast-forward") {
      if $replace {
        adopt-origin $root
        warning "Discarded local private-state commits in favor of the provided state"
        return {synced: true status: "replaced"}
      }
      warning "Private state has diverged from origin; leaving it unchanged"
      return {synced: false status: "diverged"}
    }
    let detail = (if ($pulled.stderr | str trim | is-empty) { $pulled.stdout } else { $pulled.stderr })
    let detail = (scrub-url ($detail | str trim))
    fail $"Could not sync the private state from (scrub-url $repository): ($detail)"
  }
  # A clean local branch that is ahead of origin holds newer unpushed state. It
  # is never overwritten by the older remote; --replace discards it to adopt the
  # remote exactly.
  let ahead = (run-command git ["-C" ($root | into string) "rev-list" "--count" "origin/main..HEAD"] --allow-failure --quiet --capture)
  if $ahead.exit_code == 0 {
    let ahead_count = ($ahead.stdout | str trim | into int)
    if $ahead_count > 0 {
      if $replace {
        adopt-origin $root
        warning "Discarded local private-state commits ahead of origin in favor of the provided state"
        return {synced: true status: "replaced"}
      }
      warning $"Local private state is ahead of origin by ($ahead_count) unpushed commits; leaving them in place; push them with 'reseed backup --commit --push'"
      return {synced: true status: "ahead"}
    }
  }
  info $"Synchronized private state from (scrub-url $repository)"
  {synced: true status: "synced"}
}

# Fast-forward pull the private state from its configured remote, refusing to
# proceed when the working tree has local changes.
export def git-pull [
  root: path # Private state root.
  config: record # Loaded configuration; git.remote and git.branch.
  --dry-run # Show the pull without running it.
] {
  let status = (git-status $root)
  if not $status.available { fail "Git is required to update the source" }
  if not $status.repository { warning "Source is not a Git repository; skipping pull"; return }
  if not $status.clean { fail "Source has local changes; commit or stash them before update" }
  let remote = ($config.git.remote? | default origin)
  let branch = ($config.git.branch? | default main)
  run-command git ["-C" ($root | into string) "pull" "--ff-only" $remote $branch] --dry-run=$dry_run | ignore
}

# Commit all changes in the private state, initializing the repository first
# when needed, and optionally push the new commit to the configured remote.
export def git-commit [
  root: path # Private state root.
  config: record # Loaded configuration; git.remote and git.branch.
  message: string # Commit message.
  --push # Push the new commit after committing.
  --dry-run # Show Git commands without running them.
] {
  let status = (git-status $root)
  if not $status.repository { git-init $root $config --dry-run=$dry_run }
  run-command git ["-C" ($root | into string) "add" "--all"] --dry-run=$dry_run | ignore
  # After staging, a clean working tree means there was nothing to commit;
  # in a dry run we cannot know, so assume there would be a change.
  let changed = if $dry_run { true } else { not (git-status $root).clean }
  if not $changed { info "No source changes to commit"; return }
  run-command git ["-C" ($root | into string) "commit" "-m" $message] --dry-run=$dry_run | ignore
  if $push {
    let remote = ($config.git.remote? | default origin)
    let branch = ($config.git.branch? | default main)
    run-command git ["-C" ($root | into string) "push" $remote $branch] --dry-run=$dry_run | ignore
  }
}

# Platform tag for bundled tools, normalizing architecture names the way
# release assets do: amd64 on 64-bit Windows, arm64 on Apple Silicon.
def bundle-platform []: nothing -> string {
  let os = (detect-os)
  let arch = ($nu.os-info.arch | str lowercase)
  let normalized = if $os == "windows" and $arch == "x86_64" {
    "amd64"
  } else if $os == "macos" and $arch == "aarch64" {
    "arm64"
  } else {
    $arch
  }
  $"($os)-($normalized)"
}

# Archive the committed state of a repository into a directory. Using git
# archive rather than copying guarantees ignored and untracked files stay out
# of the bundle; the repository must be clean with at least one commit.
def archive-git-root [root: path target: path archive: path label: string]: nothing -> string {
  let status = (git-status $root)
  if not $status.repository {
    fail $"Secure bundles require the ($label) root to be a Git repository: ($root)"
  }
  let head = (run-command git ["-C" ($root | into string) "rev-parse" "--verify" "HEAD"] --allow-failure --quiet --capture)
  if $head.exit_code != 0 { fail $"Bundle creation requires a commit in the ($label) repository" }
  let tracked_changes = (run-command git ["-C" ($root | into string) "status" "--porcelain" "--untracked-files=no"] --quiet --capture)
  if not ($tracked_changes.stdout | str trim | is-empty) {
    fail $"The ($label) repository has uncommitted tracked changes"
  }
  mkdir $target
  run-command git [
    "-C" ($root | into string) "archive" "--format=tar"
    $"--output=($archive)" "HEAD"
  ] | ignore
  run-command tar ["-xf" ($archive | into string) "-C" ($target | into string)] | ignore
  rm --force $archive
  $head.stdout | str trim
}

# Copy bundle payloads into the staging directory. Payload paths are relative
# to the state root unless they are ~ paths; colliding base names are rejected.
def bundle-payloads [
  state_root: path # Private state root.
  package: path # Staging package directory.
  extras: list<string> # Configured payload paths.
]: nothing -> nothing {
  if ($extras | is-empty) { return }
  let payload_dir = ($package | path join "payloads")
  mkdir $payload_dir
  mut names = []
  for configured in $extras {
    let source = if ($configured == "~") or ($configured | str starts-with "~/") or ($configured | str starts-with "~\\") {
      expand-home $configured
    } else {
      $state_root | path join $configured
    }
    if not ($source | path exists) {
      warning $"Bundle payload does not exist: ($source)"
      continue
    }
    let name = ($source | path basename)
    if $name in $names { fail $"Bundle payload names collide: ($name)" }
    $names = ($names | append $name)
    cp --recursive $source $payload_dir
  }
}

# Copy bootstrap tools into the engine/tools/<platform> directory of the
# staging package. Each copy is smoke-tested with --version and removed when
# it fails; a SHA256SUMS file is written next to the tools.
def bundle-tools [
  tools: list<string> # Tool names to bundle when available.
  tool_dir: path # Destination directory inside the staging package.
]: nothing -> nothing {
  if ($tools | is-empty) { return }
  mkdir $tool_dir
  for name in $tools {
    let matches = (which $name | where type == external)
    if ($matches | is-empty) {
      warning $"Bootstrap tool is unavailable and was not bundled: ($name)"
      continue
    }
    let source = ($matches | first | get path | path expand)
    let copied = (try {
      cp $source $tool_dir
      true
    } catch {|error|
      warning $"Bootstrap tool could not be copied: ($name): ($error.msg? | default ($error | to nuon))"
      false
    })
    if not $copied { continue }
    let copied_path = ($tool_dir | path join ($source | path basename))
    let smoke = (try {
      run-command ($copied_path | into string) ["--version"] --allow-failure --quiet --capture
    } catch {|error|
      {exit_code: 127 stdout: "" stderr: ($error.msg? | default ($error | to nuon))}
    })
    if $smoke.exit_code != 0 {
      warning $"Bundled tool failed its smoke test and was removed: ($name): ($smoke.stderr | str trim)"
      rm --force ($copied_path | into string)
    }
  }
  let checksums = (ls $tool_dir
    | where type == file
    | get name
    | each {|path| $"((open $path | hash sha256))  ($path | path basename)" })
  if ($checksums | is-not-empty) {
    $checksums | str join "\n" | save --force ($tool_dir | path join "SHA256SUMS")
  }
}

# Create the offline source bundle: git archives of the engine and private
# state, a bundle manifest, optional payloads and platform bootstrap tools,
# all compressed into a single tar.gz at the requested output path.
export def git-bundle [
  engine_root: path # Engine directory.
  state_root: path # Private state root.
  output: path # Destination archive path.
  config: record # Loaded configuration; bundle.include_tools and bundle.paths.
  --dry-run # Report bundle contents without creating the archive.
] {
  let output_path = ($output | path expand --no-symlink)
  let output_parent = ($output_path | path dirname)
  let tools = ($config.bundle.include_tools? | default [])
  let extras = ($config.bundle.paths? | default [])
  if $dry_run {
    info $"would bundle committed engine: ($engine_root)"
    info $"would bundle committed private state: ($state_root)"
    info $"would write offline bundle: ($output_path)"
    for name in $tools { info $"would include bootstrap tool when available: ($name)" }
    for configured in $extras { info $"would include payload: ($configured)" }
    return
  }

  if not (command-exists tar) { fail "Creating a bundle requires tar" }
  mkdir $output_parent

  let staging = (mktemp --directory)
  let package = ($staging | path join "reseed")
  mkdir $package
  let engine_revision = (archive-git-root
    $engine_root
    ($package | path join "engine")
    ($staging | path join "engine.tar")
    "engine")
  let state_revision = (archive-git-root
    $state_root
    ($package | path join "state")
    ($staging | path join "state.tar")
    "private state")
  {
    schema: 1
    platform: (bundle-platform)
    engine_revision: $engine_revision
    state_revision: $state_revision
  } | to nuon --indent 2 | save --force ($package | path join "bundle.nuon")

  bundle-payloads $state_root $package $extras
  bundle-tools $tools ($package | path join "engine" "tools" (bundle-platform))

  run-command tar ["-czf" ($output_path | into string) "-C" ($staging | into string) "reseed"] | ignore
  rm --recursive --force $staging
  info $"Source bundle: ($output_path)"
}

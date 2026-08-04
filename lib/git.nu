use core.nu [command-exists detect-os expand-home fail info run-command warning]

export def git-status [root: path]: nothing -> record {
  if not (command-exists git) {
    return {available: false repository: false clean: null branch: null}
  }
  let probe = (run-command git ["-C" ($root | into string) "rev-parse" "--is-inside-work-tree"] --allow-failure --quiet)
  if $probe.exit_code != 0 {
    return {available: true repository: false clean: null branch: null}
  }
  let changes = (run-command git ["-C" ($root | into string) "status" "--porcelain"] --quiet)
  let branch = (run-command git ["-C" ($root | into string) "branch" "--show-current"] --quiet)
  {
    available: true
    repository: true
    clean: ($changes.stdout | str trim | is-empty)
    branch: ($branch.stdout | str trim)
  }
}

export def git-init [
  root: path
  config: record
  --remote-url: string
  --dry-run
] {
  let status = (git-status $root)
  if not $status.available { fail "Git is required to initialize the Reseed source" }
  let branch = ($config.git.branch? | default main)
  let remote = ($config.git.remote? | default origin)
  if not $status.repository {
    run-command git ["-C" ($root | into string) "init" "-b" $branch] --dry-run=$dry_run | ignore
  } else {
    info $"Git repository already initialized: ($root)"
    if ($status.branch | str trim | is-empty) {
      let branch_ref = $"refs/heads/($branch)"
      let branch_exists = (run-command git ["-C" ($root | into string) "show-ref" "--verify" $branch_ref] --allow-failure --quiet)
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
      let existing = (run-command git ["-C" ($root | into string) "remote" "get-url" $remote] --allow-failure --quiet)
      if $existing.exit_code == 0 {
        let current = ($existing.stdout | str trim)
        if $current != $remote_url {
          fail $"Git remote '($remote)' already points to ($current); refusing to replace it with ($remote_url)"
        }
        info $"Git remote '($remote)' already configured: ($current)"
      } else {
        run-command git ["-C" ($root | into string) "remote" "add" $remote $remote_url] --dry-run=$dry_run | ignore
      }
    }
  }
  info $"Reseed source repository: ($root)"
}

export def git-pull [root: path config: record --dry-run] {
  let status = (git-status $root)
  if not $status.available { fail "Git is required to update the source" }
  if not $status.repository { warning "Source is not a Git repository; skipping pull"; return }
  if not $status.clean { fail "Source has local changes; commit or stash them before update" }
  let remote = ($config.git.remote? | default origin)
  let branch = ($config.git.branch? | default main)
  run-command git ["-C" ($root | into string) "pull" "--ff-only" $remote $branch] --dry-run=$dry_run | ignore
}

export def git-commit [root: path config: record message: string --push --dry-run] {
  let status = (git-status $root)
  if not $status.repository { git-init $root $config --dry-run=$dry_run }
  run-command git ["-C" ($root | into string) "add" "--all"] --dry-run=$dry_run | ignore
  let changed = if $dry_run { true } else { not (git-status $root).clean }
  if not $changed { info "No source changes to commit"; return }
  run-command git ["-C" ($root | into string) "commit" "-m" $message] --dry-run=$dry_run | ignore
  if $push {
    let remote = ($config.git.remote? | default origin)
    let branch = ($config.git.branch? | default main)
    run-command git ["-C" ($root | into string) "push" $remote $branch] --dry-run=$dry_run | ignore
  }
}

def bundle-platform []: nothing -> string {
  let os = (detect-os)
  let arch = ($nu.os-info.arch | str downcase)
  let normalized = if $os == "windows" and $arch == "x86_64" {
    "amd64"
  } else if $os == "macos" and $arch == "aarch64" {
    "arm64"
  } else {
    $arch
  }
  $"($os)-($normalized)"
}

def archive-git-root [root: path target: path archive: path label: string]: nothing -> string {
  let status = (git-status $root)
  if not $status.repository {
    fail $"Secure bundles require the ($label) root to be a Git repository: ($root)"
  }
  let head = (run-command git ["-C" ($root | into string) "rev-parse" "--verify" "HEAD"] --allow-failure --quiet)
  if $head.exit_code != 0 { fail $"Bundle creation requires a commit in the ($label) repository" }
  let tracked_changes = (run-command git ["-C" ($root | into string) "status" "--porcelain" "--untracked-files=no"] --quiet)
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

export def git-bundle [engine_root: path state_root: path output: path config: record --dry-run] {
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

  if not ($extras | is-empty) {
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

  if not ($tools | is-empty) {
    let tool_dir = ($package | path join "engine" "tools" (bundle-platform))
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
    }
    let checksums = (ls $tool_dir
      | where type == file
      | get name
      | each {|path| $"((open $path | hash sha256))  ($path | path basename)" })
    if ($checksums | is-not-empty) {
      $checksums | str join "\n" | save --force ($tool_dir | path join "SHA256SUMS")
    }
  }

  run-command tar ["-czf" ($output_path | into string) "-C" ($staging | into string) "reseed"] | ignore
  rm --recursive --force $staging
  info $"Source bundle: ($output_path)"
}

# Recovered state import: validate a downloaded private-state source, stage
# its contents, and atomically import them into the authoritative local root.
#
# Sources are immutable recovery artifacts: they are never initialized, seeded,
# updated, or assigned a remote. Git-checkout sources are cloned locally without
# hardlinks and their working-tree delta (modified, deleted, and non-ignored
# untracked files) is overlaid on top; bundle and raw-snapshot sources copy
# their non-ignored state files and retain any available revision metadata.
# Every import records its fingerprint, source kind, source revision, and the
# destination identity under the disposable state directory, so a rerun with
# the same source is a no-op and a different source against an initialized root
# is refused without modifying either location.

use core.nu [command-exists detect-os fail info run-command scrub-url state-sentinel-exists warning]
use config.nu [load-config validate-config]
use repo.nu [import-record-load import-record-path repo-key repo-probe]
use state.nu [state-root]

# Whether a path names a bundle archive (tar.gz, tgz, or tar).
def bundle-archive? [source: path]: nothing -> bool {
  let name = ($source | path basename | str lowercase)
  ($name | str ends-with ".tar.gz") or ($name | str ends-with ".tgz") or ($name | str ends-with ".tar")
}

# Classify a state source: git-checkout (a directory with .git), bundle (an
# archive containing reseed/bundle.nuon), or raw-snapshot (a directory).
def source-kind [source: path]: nothing -> string {
  if ($source | path type) == "file" and (bundle-archive? $source) {
    "bundle"
  } else if ($source | path type) == "dir" and (($source | path join ".git") | path exists) {
    "git-checkout"
  } else {
    "raw-snapshot"
  }
}

# Extract a bundle archive into a temporary directory and return the path of
# its state snapshot plus the recorded state_revision (when present).
def unpack-bundle [source: path]: nothing -> record {
  let extract = (mktemp --directory)
  let extracted = (run-command tar ["-xf" ($source | into string) "-C" ($extract | into string)] --allow-failure --quiet --capture)
  if $extracted.exit_code != 0 {
    rm --recursive --force $extract
    fail $"The state source is not a readable bundle archive: (scrub-url ($source | into string))"
  }
  let package = ($extract | path join "reseed")
  let state_dir = ($package | path join "state")
  let manifest = ($package | path join "bundle.nuon")
  if not (($state_dir | path exists) and (state-sentinel-exists $state_dir)) {
    rm --recursive --force $extract
    fail $"The bundle does not contain a private-state snapshot: ($source)"
  }
  let revision = if ($manifest | path exists) {
    let meta = (try { open $manifest } catch { {} })
    if ($meta | describe) =~ '^record' { $meta.state_revision? | default "" } else { "" }
  } else { "" }
  {config_root: $state_dir revision: $revision extract: $extract}
}

# Relative paths of the non-ignored state files under a directory. Git
# checkouts enumerate tracked plus untracked non-ignored files; plain
# directories are enumerated through a scratch repository so .gitignore is
# honored without reimplementing its pattern language.
def snapshot-files [root: path]: nothing -> list<string> {
  if (($root | path join ".git") | path exists) {
    let listed = (run-command git ["-C" ($root | into string) "ls-files" "-co" "--exclude-standard" "-z"] --allow-failure --quiet --capture)
    if $listed.exit_code != 0 { return [] }
    $listed.stdout
      | split row "\u{0}"
      | where {|rel| not ($rel | is-empty) and (($root | path join $rel) | path exists) }
    | sort
  } else {
    let scratch = (mktemp --directory)
    try {
      run-command git ["-C" ($scratch | into string) "init" "-q" "-b" "main"] --quiet | ignore
      for entry in (ls --all $root) {
        if ($entry.name == ".") or ($entry.name == "..") { continue }
        cp --recursive $entry.name ($scratch | path join ($entry.name | path basename))
      }
      let status = (run-command git ["-C" ($scratch | into string) "status" "--porcelain" "-z" "--untracked-files=all"] --allow-failure --quiet --capture)
      if $status.exit_code != 0 { return [] }
      $status.stdout
        | split row "\u{0}"
        | where {|field| ($field | str length) >= 4 }
        | each {|field| $field | str substring 3.. }
        | where {|rel| not ($rel | is-empty) and (($root | path join $rel) | path exists) }
      | sort
    } catch {|error|
      warning $"Could not enumerate state source files: ($error.msg? | default ($error | to nuon))"
      []
    } finally { rm --recursive --force $scratch }
  }
}

# Hash the non-ignored files of a source together with its kind and revision:
# the immutable fingerprint used to recognize identical reruns and to refuse
# a different source against an initialized root.
def source-fingerprint [root: path, kind: string, revision: string]: nothing -> string {
  let content = (snapshot-files $root
    | each {|rel|
      let path = ($root | path join $rel)
      let hash = (try { open --raw $path | hash sha256 } catch { "unreadable" })
      $"($rel):($hash)"
    }
    | str join "\n")
  $"($kind)\n($revision)\n($content)" | hash sha256
}

# The git revision of a git-checkout source (HEAD), or the recorded
# state_revision for bundle sources, or "" when unknown.
def source-revision [kind: string, config_root: path, bundle_revision: string]: nothing -> string {
  if $kind == "git-checkout" {
    let head = (run-command git ["-C" ($config_root | into string) "rev-parse" "--verify" "HEAD"] --allow-failure --quiet --capture)
    if $head.exit_code == 0 { $head.stdout | str trim } else { "" }
  } else {
    $bundle_revision
  }
}

# Copy the enumerated non-ignored files from a source directory into a staging
# directory.
def copy-snapshot-files [root: path, staging: path, rels: list<string>] {
  for rel in $rels {
    let source = ($root | path join $rel)
    let target = ($staging | path join $rel)
    if ($source | path exists) {
      mkdir ($target | path dirname)
      cp --recursive $source $target
    }
  }
}

# Overlay the working-tree delta of a git checkout (modified, added, deleted,
# renamed, and non-ignored untracked files) onto a freshly cloned staging
# directory.
def overlay-source-delta [source: path, staging: path] {
  let status = (run-command git ["-C" ($source | into string) "status" "--porcelain" "-z" "--untracked-files=all"] --allow-failure --quiet --capture)
  if $status.exit_code != 0 { fail $"Cannot read the state source working tree: ($source)" }
  let fields = ($status.stdout | split row "\u{0}")
  mut index = 0
  while $index < ($fields | length) {
    let field = ($fields | get $index)
    if ($field | str length) < 4 { $index += 1; continue }
    let code = ($field | str substring 0..<1)
    let rel = ($field | str substring 3..)
    if $code == "R" or $code == "C" {
      # Rename/copy entries carry the original path in the next field.
      let original = ($fields | get ($index + 1))
      if $code == "R" {
        let target = ($staging | path join $original)
        if ($target | path exists) { rm --recursive --force $target }
      }
      let source_path = ($source | path join $rel)
      if ($source_path | path exists) {
        let target = ($staging | path join $rel)
        mkdir ($target | path dirname)
        cp --recursive $source_path $target
      }
      $index += 2
    } else if $code == "D" {
      let target = ($staging | path join $rel)
      if ($target | path exists) { rm --recursive --force $target }
      $index += 1
    } else {
      let source_path = ($source | path join $rel)
      if ($source_path | path exists) {
        let target = ($staging | path join $rel)
        mkdir ($target | path dirname)
        cp --recursive $source_path $target
      }
      $index += 1
    }
  }
}

# Stage an imported source into a fresh directory ready to swap into place.
def stage-source [
  source: path # State source.
  kind: string # Detected source kind.
  config_root: path # Directory whose non-ignored files form the state.
]: nothing -> path {
  let staging = (mktemp --directory)
  if $kind == "git-checkout" {
    let cloned = (run-command git ["clone" "--quiet" "--no-hardlinks" ($source | into string) ($staging | into string)] --allow-failure --quiet --capture)
    if $cloned.exit_code != 0 {
      rm --recursive --force $staging
      fail $"Could not clone the state source: ($cloned.stderr | str trim)"
    }
    overlay-source-delta $source $staging
    # A cloned source records its origin remote; keep it when it points at a
    # real repository so the recovered machine can push straight back, but
    # drop local file paths (the source directory itself is not a remote).
    let origin = (run-command git ["-C" ($staging | into string) "remote" "get-url" "origin"] --allow-failure --quiet --capture)
    if $origin.exit_code == 0 {
      let url = ($origin.stdout | str trim)
      let keep = (($url | str contains "://") or ($url | str starts-with "git@"))
      if not $keep {
        run-command git ["-C" ($staging | into string) "remote" "remove" "origin"] --quiet | ignore
      }
    }
  } else {
    copy-snapshot-files $config_root $staging (snapshot-files $config_root)
  }
  $staging
}

# Atomically replace the destination root with the staged tree, keeping a
# same-directory backup so a failure restores the previous state. The recovered
# snapshot is authoritative: seed-only files from a previous template root are
# not carried over, so the imported state stays clean and committed.
def swap-state [state_root: path, staging: path, config: record, record: record] {
  let parent = ($state_root | path dirname)
  mkdir $parent
  let backup = ($parent | path join $".reseed-import-(random uuid)")
  let had_root = ($state_root | path exists)
  if $had_root { mv $state_root $backup }
  try {
    mv $staging $state_root
    # Persist the import receipt while the backup still exists, so a receipt
    # failure rolls the whole import back instead of leaving a committed root
    # with no way to retry.
    let record_path = (import-record-path $state_root $config)
    mkdir ($record_path | path dirname)
    $record | to nuon --indent 2 | save --force $record_path
  } catch {|error|
    if ($state_root | path exists) { rm --recursive --force $state_root }
    if $had_root and ($backup | path exists) { mv $backup $state_root }
    if ($staging | path exists) { rm --recursive --force $staging }
    fail $"Import failed; the previous state was restored: ($error.msg? | default ($error | to nuon))"
  }
  if $had_root and ($backup | path exists) { rm --recursive --force $backup }
}

# Create the initial snapshot commit for a bundle or raw-snapshot import so the
# recovered state is a committed, pushable repository. Git checkouts already
# carry full history and are left untouched. The synthetic commit never inherits
# the host's commit-signing configuration: signing may be enabled while the key
# is not yet set up, which would block recovery before `reseed setup` can fix it.
def ensure-snapshot-commit [root: path, config: record, kind: string, revision: string, --dry-run] {
  if $kind == "git-checkout" { return }
  let branch = (($config.git? | default {}).branch? | default main)
  if not (($root | path join ".git") | path exists) {
    run-command git ["-C" ($root | into string) "init" "-q" "-b" $branch] --dry-run=$dry_run --quiet | ignore
  }
  let email = (run-command git ["-C" ($root | into string) "config" "user.email"] --allow-failure --quiet --capture)
  let name = (run-command git ["-C" ($root | into string) "config" "user.name"] --allow-failure --quiet --capture)
  if $email.exit_code != 0 {
    run-command git ["-C" ($root | into string) "config" "user.email" "reseed@local"] --dry-run=$dry_run --quiet | ignore
  }
  if $name.exit_code != 0 {
    run-command git ["-C" ($root | into string) "config" "user.name" "Reseed"] --dry-run=$dry_run --quiet | ignore
  }
  run-command git ["-C" ($root | into string) "add" "--all"] --dry-run=$dry_run --quiet | ignore
  let message = (if ($revision | is-empty) { "Import recovered state snapshot" } else { $"Import recovered state snapshot (($revision))" })
  run-command git ["-C" ($root | into string) "-c" "commit.gpgsign=false" "commit" "-m" $message "--allow-empty"] --dry-run=$dry_run --quiet | ignore
}

# Validate a supplied state source and report its kind, revision, and
# fingerprint. Failures abort before any destination is touched.
export def state-source-probe [
  source: path # State source path.
  profiles: list<string> # Profiles used to validate the selected configuration.
]: nothing -> record {
  let source = ($source | path expand --no-symlink)
  if not ($source | path exists) { fail $"State source does not exist: ($source)" }
  let kind = (source-kind $source)
  let bundle = if $kind == "bundle" { unpack-bundle $source } else { null }
  let config_root = if $kind == "bundle" { $bundle.config_root } else { $source }
  try {
    if not (state-sentinel-exists $config_root) {
      fail $"State source lacks the .reseed-state sentinel: ($config_root)"
    }
    let config = (load-config $config_root $profiles)
    let errors = (validate-config $config_root $config | where level == error)
    if ($errors | is-not-empty) {
      $errors | table | print --stderr
      fail "The state source configuration is invalid"
    }
    let revision = (source-revision $kind $config_root ($bundle.revision? | default ""))
    let fingerprint = (source-fingerprint $config_root $kind $revision)
    {kind: $kind config_root: $config_root config: $config revision: $revision fingerprint: $fingerprint extract: (if $bundle == null { null } else { $bundle.extract })}
  } catch {|error|
    if $bundle != null and ($bundle.extract | path exists) { rm --recursive --force $bundle.extract }
    error make {msg: ($error.msg? | default ($error | to nuon))}
  }
}

# Import a supplied state source into the authoritative local root, recording
# its fingerprint under the disposable state directory. A rerun with the same
# source is a no-op; a different source against an initialized root is refused
# without modifying either location. Dry runs validate and report without
# writing.
export def import-state-source [
  state_root: path # Writable destination root.
  source: path # State source to import.
  profiles: list<string> # Profiles used to validate the selected configuration.
  --dry-run
]: nothing -> record {
  let state_root = ($state_root | path expand --no-symlink)
  let source = ($source | path expand --no-symlink)
  if ($source | into string) == ($state_root | into string) {
    fail "--state-source must differ from --state-root"
  }
  let probed = (state-source-probe $source $profiles)
  let config = $probed.config
  let kind = $probed.kind
  try {
    let existing_record = (import-record-load $state_root $config)
    if $existing_record != null and ($existing_record.fingerprint? | default "") == $probed.fingerprint {
      info "State source already imported; nothing to do"
      return {status: "no-op" kind: $kind revision: $probed.revision fingerprint: $probed.fingerprint}
    }

    let probe = (repo-probe $state_root $config)
    if $probe.repository and $probe.committed {
      fail $"Refusing to import a different state source over initialized local state at ($state_root); use 'reseed adopt --replace' or 'reseed sync' to reconcile instead"
    }

    if $dry_run {
      info $"would import ($kind) state source: ($source)"
      if not ($probed.revision | is-empty) { info $"source revision: ($probed.revision)" }
      info $"source fingerprint: ($probed.fingerprint)"
      return {status: "would-import" kind: $kind revision: $probed.revision fingerprint: $probed.fingerprint config: $config config_root: $probed.config_root}
    }

    let staging = (stage-source $source $kind $probed.config_root)
    # Commit the snapshot inside staging (bundle/raw) so the swap brings in a
    # committed repository atomically; a commit failure aborts before the
    # destination is touched.
    ensure-snapshot-commit $staging $config $kind $probed.revision --dry-run=$dry_run

    let record = {
      schema: 1
      destination: ($state_root | into string)
      platform: (detect-os)
      source: ($source | into string)
      kind: $kind
      revision: $probed.revision
      state_revision: (if $kind == "bundle" { $probed.revision } else { "" })
      fingerprint: $probed.fingerprint
      imported_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
    }
    swap-state $state_root $staging $config $record
    info $"Imported ($kind) state source into ($state_root)"
    {status: "imported" kind: $kind revision: $probed.revision fingerprint: $probed.fingerprint config: $config config_root: $state_root}
  } finally {
    if ($probed.extract? | default "") != "" and ($probed.extract | path exists) { rm --recursive --force $probed.extract }
  }
}

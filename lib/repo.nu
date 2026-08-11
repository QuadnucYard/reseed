# The private state repository state machine and synchronization operations.
#
# A single probe (`repo-probe`) reports the repository as a set of machine
# readable facts plus a derived phase, and one implementation (`repo-sync`)
# drives status, `reseed sync`, bootstrap refresh, and update. Merge intent is
# persisted outside the repository so `sync --continue` and `sync --abort`
# survive an interrupted merge.

use core.nu [command-exists confirm detect-os fail info run-command scrub-url state-sentinel-exists warning]
use secrets.nu [commit-change-summary scan-commit-secrets]
use state.nu [state-root]

# Effective git settings from the configuration with defaults. Tolerates a
# config record with no git section (for example the empty fallback used when
# the configuration cannot be loaded).
def repo-settings [config: record]: nothing -> record {
  let git = ($config.git? | default {})
  {
    remote: ($git.remote? | default origin)
    branch: ($git.branch? | default main)
    url: ($git.url? | default "")
  }
}

# Run a git command against a repository, returning the captured result.
def git-in [root: path, args: list<string>]: nothing -> record {
  run-command git (["-C" ($root | into string)] | append $args) --allow-failure --quiet --capture
}

# Environment that bounds remote probes over SSH without overriding a user's
# own GIT_SSH_COMMAND: batch mode never hangs on a password prompt and a
# connect timeout caps a blocked host. HTTPS transfers are bounded separately
# by git's low-speed settings.
def probe-environment []: nothing -> record {
  let ssh = ($env.GIT_SSH_COMMAND? | default "ssh -o BatchMode=yes -o ConnectTimeout=10")
  {GIT_SSH_COMMAND: $ssh}
}

# True when a probe target is a real remote (http/https/ssh/git/scp-like URL)
# rather than a local path. Local repositories do not need a deadline, so the
# tests (and fast local probes) skip the wrapper entirely.
def remote-url? [url: string]: nothing -> bool {
  ($url | str contains "://") or ($url | str starts-with "git@") or ($url | str starts-with "ssh:")
}

# Run a git command against a repository with the bounded probe environment.
def git-in-probe [root: path, args: list<string>]: nothing -> record {
  # The fetch target is the second-to-last argument; bound only real remotes.
  let target = (if ($args | length) >= 2 { $args | get (($args | length) - 2) } else { "" })
  run-command git (["-C" ($root | into string)] | append $args) --allow-failure --quiet --capture --environment=(probe-environment) --timeout=(if (remote-url? $target) { 60 } else { 0 })
}

# Bounded, read-only remote listing. The low-speed settings bound HTTP
# transfers, the probe environment bounds SSH, and a real process deadline
# kills a probe that stalls before any transfer begins. Local paths skip the
# deadline entirely.
def remote-refs [remote_url: string]: nothing -> record {
  run-command git [
    "-c" "http.lowSpeedLimit=1" "-c" "http.lowSpeedTime=15"
    "ls-remote" "--heads" $remote_url
  ] --allow-failure --quiet --capture --environment=(probe-environment) --timeout=(if (remote-url? $remote_url) { 20 } else { 0 })
}

# Default branch of a remote repository, resolved from its symbolic HEAD, or
# "main" when the remote cannot be read or has no symbolic default.
export def remote-default-branch [repository: string]: nothing -> string {
  let sym = (run-command git ["ls-remote" "--symref" $repository "HEAD"] --allow-failure --quiet --capture --environment=(probe-environment) --timeout=(if (remote-url? $repository) { 20 } else { 0 }))
  if $sym.exit_code != 0 { return "main" }
  let line = ($sym.stdout | lines | where {|line| $line | str starts-with "ref:" } | get 0? | default "")
  if ($line | is-empty) { "main" } else { $line | str replace --regex '.*refs/heads/' "" | str replace --regex '\t.*$' "" | str trim }
}

# Compute local ahead/behind against the remote-tracking ref for the
# configured branch, leaving both null when there is no shared ancestor
# (an unknown-base snapshot) or the ref is unavailable.
def compute-ahead-behind [
  root: path
  facts: record # Facts updated in place.
  settings: record # Configured remote and branch.
]: nothing -> record {
  let tracking = $"refs/remotes/($settings.remote)/($settings.branch)"
  let base = (git-in $root ["merge-base" "HEAD" $tracking])
  if $base.exit_code != 0 { return $facts }
  let ahead = (git-in $root ["rev-list" "--count" $"($tracking)..HEAD"])
  let behind = (git-in $root ["rev-list" "--count" $"HEAD..($tracking)"])
  mut result: any = $facts
  if $ahead.exit_code == 0 { $result = ($result | upsert ahead ($ahead.stdout | str trim | into int)) }
  if $behind.exit_code == 0 { $result = ($result | upsert behind ($behind.stdout | str trim | into int)) }
  $result
}

# Classify the probed facts into a single state-machine phase.
def derive-phase [facts: record]: nothing -> string {
  if not $facts.git_available { return "no-git" }
  if not $facts.repository { return (if $facts.sentinel { "no-repo" } else { "uninitialized" }) }
  if not $facts.committed { return "unborn" }
  if $facts.merge_in_progress { return "merge-in-progress" }
  if $facts.detached { return "detached" }
  if $facts.shallow { return "shallow" }
  if $facts.remote.mismatch == true { return "mismatched" }
  if $facts.remote.reachable == false { return "inaccessible" }
  if $facts.remote.reachable == true {
    if $facts.remote.empty == true { return "empty-remote" }
    if $facts.remote.has_branch == false { return "missing-branch" }
  }
  if $facts.clean == false { return "dirty" }
  if $facts.remote_ahead == true { return "behind" }
  if ($facts.ahead != null) and ($facts.behind != null) and ($facts.ahead > 0) and ($facts.behind > 0) { return "diverged" }
  if ($facts.ahead != null) and ($facts.ahead > 0) { return "ahead" }
  if ($facts.behind != null) and ($facts.behind > 0) { return "behind" }
  # The remote branch is present but the local snapshot shares no ancestor: a
  # recovered state with unknown provenance. It needs a reviewed merge rather
  # than a claim of synchronization.
  if ($facts.remote.reachable == true) and ($facts.remote.has_branch == true) and ($facts.ahead == null) and ($facts.behind == null) { return "unknown-base" }
  # Offline probes that found no cached remote state cannot classify the
  # relationship; report that explicitly rather than claiming synchronization.
  if ($facts.remote.reachable == null) and ($facts.ahead == null) and ($facts.behind == null) and not ($facts.remote_url | is-empty) { return "offline-unknown" }
  if ($facts.remote.reachable == null) and ($facts.ahead == null) and ($facts.behind == null) and ($facts.remote_url | is-empty) { return "no-remote" }
  "clean-synced"
}

# Compute ahead/behind in read-only mode from the remote branch tip reported
# by ls-remote, without fetching. When the tip's objects are already local the
# exact counts are computed; when the remote tip is not local the remote has
# unpulled commits, which is flagged as remote_ahead so status never reports
# "synchronized" against a stale tip.
def readonly-ahead-behind [
  root: path
  facts: record # Facts updated in place.
  settings: record # Configured remote and branch.
  remote_sha: string # The remote branch tip from ls-remote.
]: nothing -> record {
  mut result: any = $facts
  $result = ($result | upsert remote.head $remote_sha | upsert remote_ahead false)
  let head = ($facts.head | default "")
  if ($remote_sha | is-empty) or ($head | is-empty) { return $result }
  if $remote_sha == $head {
    return ($result | upsert ahead 0 | upsert behind 0)
  }
  let local_obj = (git-in $root ["cat-file" "-e" $remote_sha])
  if $local_obj.exit_code != 0 {
    # The remote tip is not present locally: the remote has commits we lack.
    return ($result | upsert remote_ahead true)
  }
  let base = (git-in $root ["merge-base" "HEAD" $remote_sha])
  if $base.exit_code != 0 { return $result }
  let ahead = (git-in $root ["rev-list" "--count" $"($remote_sha)..HEAD"])
  let behind = (git-in $root ["rev-list" "--count" $"HEAD..($remote_sha)"])
  if $ahead.exit_code == 0 { $result = ($result | upsert ahead ($ahead.stdout | str trim | into int)) }
  if $behind.exit_code == 0 { $result = ($result | upsert behind ($behind.stdout | str trim | into int)) }
  $result
}

# Probe the private state root and report machine readable facts plus a
# derived phase. With --offline only local and cached facts are consulted;
# otherwise a bounded remote probe updates the reachability facts. The default
# probe also fetches the configured branch into its remote-tracking ref (the
# cache used by offline status); --read-only probes the remote without
# fetching, using the cached remote-tracking ref for ahead/behind. The remote
# URL resolution order is: the existing origin URL, then --remote-url, then
# config.git.url.
export def repo-probe [
  root: path # Private state root.
  config: record # Loaded configuration; git.remote, git.branch, and git.url.
  --remote-url: string = "" # Requested remote URL (overrides git.url only).
  --offline # Skip the remote probe; use local and cached facts.
  --read-only # Probe the remote without fetching; use cached ahead/behind.
]: nothing -> record {
  let settings = (repo-settings $config)
  let root = ($root | path expand --no-symlink)
  mut facts: any = {
    platform: (detect-os)
    state_root: $root
    git_available: (command-exists git)
    repository: false
    sentinel: (state-sentinel-exists $root)
    committed: false
    clean: null
    branch: ""
    detached: false
    shallow: false
    merge_in_progress: false
    remote_name: $settings.remote
    remote_url: ""
    head: ""
    ahead: null
    behind: null
    remote_ahead: false
    remote: {reachable: null empty: null has_branch: null head: null mismatch: null}
    phase: null
  }
  if not $facts.git_available {
    $facts = ($facts | upsert phase "no-git")
    return $facts
  }
  let worktree = (git-in $root ["rev-parse" "--is-inside-work-tree"])
  if $worktree.exit_code != 0 {
    $facts = ($facts | upsert phase (if $facts.sentinel { "no-repo" } else { "uninitialized" }))
    return $facts
  }
  $facts = ($facts | upsert repository true)
  let head = (git-in $root ["rev-parse" "--verify" "HEAD"])
  if $head.exit_code == 0 {
    $facts = ($facts | upsert committed true | upsert head ($head.stdout | str trim))
  }
  let symbolic = (git-in $root ["symbolic-ref" "-q" "HEAD"])
  $facts = ($facts | upsert detached ($symbolic.exit_code != 0))
  if $symbolic.exit_code == 0 {
    $facts = ($facts | upsert branch ($symbolic.stdout | str trim | str replace "refs/heads/" ""))
  }
  let shallow = (git-in $root ["rev-parse" "--is-shallow-repository"])
  $facts = ($facts | upsert shallow (($shallow.stdout | str trim) == "true"))
  $facts = ($facts | upsert merge_in_progress (($root | path join ".git" "MERGE_HEAD") | path exists))
  let status = (git-in $root ["status" "--porcelain"])
  $facts = ($facts | upsert clean ($status.exit_code == 0 and ($status.stdout | str trim | is-empty)))

  let existing = (git-in $root ["remote" "get-url" $settings.remote])
  if $existing.exit_code == 0 {
    $facts = ($facts | upsert remote_url ($existing.stdout | str trim))
  }
  # A requested URL that differs from the configured remote is a mismatch: we
  # cannot trust which repository to talk to, so refuse to probe or act on it.
  let mismatch = (not ($remote_url | str trim | is-empty)) and not ($facts.remote_url | is-empty) and ($facts.remote_url != $remote_url)
  if $mismatch {
    $facts = ($facts | upsert remote {reachable: null empty: null has_branch: null head: null mismatch: true})
  }

  let probe_url = if not ($facts.remote_url | is-empty) {
    $facts.remote_url
  } else if not ($remote_url | str trim | is-empty) {
    $remote_url
  } else {
    $settings.url
  }
  $facts = ($facts | upsert probe_url $probe_url)

  if not $mismatch and not $offline and not ($probe_url | is-empty) {
    let ls = (remote-refs $probe_url)
    if $ls.exit_code != 0 {
      $facts = ($facts | upsert remote {reachable: false empty: null has_branch: null head: null mismatch: null})
    } else {
      let refs = ($ls.stdout | str trim)
      let empty = ($refs | is-empty)
      let has_branch = ($refs | lines | any {|line| $line | str ends-with $"refs/heads/($settings.branch)" })
      $facts = ($facts | upsert remote {reachable: true empty: $empty has_branch: $has_branch head: null mismatch: null})
      if $has_branch and not $read_only {
        # Bounded fetch into the remote-tracking ref: this is what fills the
        # cache that offline status reads, and what sync acts on.
        let fetch = (git-in-probe $root [
          "-c" "http.lowSpeedLimit=1" "-c" "http.lowSpeedTime=15"
          "fetch" $probe_url $"($settings.branch):refs/remotes/($settings.remote)/($settings.branch)"
        ])
        if $fetch.exit_code == 0 {
          let rt = (git-in $root ["rev-parse" "--verify" $"refs/remotes/($settings.remote)/($settings.branch)"])
          if $rt.exit_code == 0 {
            $facts = ($facts | upsert remote {reachable: true empty: $empty has_branch: $has_branch head: ($rt.stdout | str trim) mismatch: null})
            $facts = (compute-ahead-behind $root $facts $settings)
          }
        }
      } else if $has_branch and $facts.committed {
        # Read-only probe: compare the LOCAL branch against the ACTUAL remote
        # tip reported by ls-remote (no fetch), so status and dry runs never
        # report "synchronized" against a stale cached tip.
        let remote_sha = ($refs
          | lines
          | where {|line| $line | str ends-with $"refs/heads/($settings.branch)" }
          | get 0? | default ""
          | split row "\t" | get 0? | default "")
        $facts = (readonly-ahead-behind $root $facts $settings $remote_sha)
      }
    }
  } else if not $mismatch and $facts.committed {
    let rt = (git-in $root ["rev-parse" "--verify" $"refs/remotes/($settings.remote)/($settings.branch)"])
    if $rt.exit_code == 0 {
      $facts = ($facts | upsert remote {reachable: null empty: null has_branch: true head: ($rt.stdout | str trim) mismatch: null})
      $facts = (compute-ahead-behind $root $facts $settings)
    }
  }
  $facts | upsert phase (derive-phase $facts)
}

# Directory under the disposable state root holding per-repository sync
# records (merge intent and the like).
def repo-state-dir [config: record]: nothing -> path {
  state-root $config | path join "repo"
}

# Hash key scoping a repository record to one destination.
export def repo-key [root: path]: nothing -> string {
  (($root | path expand --no-symlink) | into string) | hash sha256
}

# Path of the merge intent record for a repository.
def merge-intent-path [root: path, config: record]: nothing -> path {
  let key = (repo-key $root)
  repo-state-dir $config | path join "merge" $"($key).nuon"
}

# Persist the merge intent outside the repository so sync --continue and
# sync --abort can complete or discard a merge after an interruption.
export def merge-intent-save [
  root: path # Private state root.
  config: record # Loaded configuration.
  intent: record # Merge intent to persist.
] {
  let path = (merge-intent-path $root $config)
  mkdir ($path | path dirname)
  $intent | to nuon --indent 2 | save --force $path
}

# Load the merge intent for a repository, or null.
export def merge-intent-load [root: path, config: record]: nothing -> any {
  let path = (merge-intent-path $root $config)
  if not ($path | path exists) { return null }
  open $path
}

# Clear the merge intent for a repository.
export def merge-intent-clear [root: path, config: record] {
  let path = (merge-intent-path $root $config)
  if ($path | path exists) { rm --force $path }
}

# Add the configured remote when missing; a mismatched existing remote was
# already reported by the probe.
def ensure-remote [root: path, settings: record, url: string, --dry-run]: nothing -> record {
  let existing = (git-in $root ["remote" "get-url" $settings.remote])
  if $existing.exit_code != 0 {
    run-command git ["-C" ($root | into string) "remote" "add" $settings.remote $url] --dry-run=$dry_run --quiet | ignore
    info $"Attached private state remote: (scrub-url $url)"
    return {added: true}
  }
  if ($existing.stdout | str trim) != $url {
    info $"Using configured private state remote: (scrub-url ($existing.stdout | str trim))"
  }
  {added: false}
}

# Initialize a sentinel-marked root that is not yet a repository and adopt the
# provided state wholesale, keeping non-colliding untracked files. Used for a
# no-repo or unborn (template seed) root when a remote is available.
def adopt-remote-state [
  root: path
  settings: record # Configured remote and branch.
  probe: record # Probe facts for the root.
  --remote-url: string = "" # Requested remote URL.
  --dry-run
]: nothing -> record {
  let probe_url = if not ($probe.remote_url | is-empty) {
    $probe.remote_url
  } else if not ($remote_url | str trim | is-empty) {
    $remote_url
  } else {
    $settings.url
  }
  if ($probe_url | is-empty) { return {synced: false status: "no-remote" detail: "no remote repository is configured; pass --remote-url or set git.url"} }
  if not $probe.repository {
    run-command git ["-C" ($root | into string) "init" "-b" $settings.branch] --dry-run=$dry_run --quiet | ignore
  }
  ensure-remote $root $settings $probe_url --dry-run=$dry_run | ignore
  let refs = (remote-refs $probe_url)
  if $refs.exit_code != 0 {
    return {synced: false status: "inaccessible" detail: $"cannot reach (scrub-url $probe_url)"}
  }
  if ($refs.stdout | str trim | is-empty) {
    info "Remote repository is empty; the local state stays as-is until it is pushed"
    return {synced: true status: "attached"}
  }
  let has_branch = ($refs.stdout | lines | any {|line| $line | str ends-with $"refs/heads/($settings.branch)" })
  if not $has_branch {
    return {synced: false status: "missing-branch" detail: $"the remote has no ($settings.branch) branch"}
  }
  let fetch = (run-command git [
    "-C" ($root | into string) "-c" "http.lowSpeedLimit=1" "-c" "http.lowSpeedTime=15"
    "fetch" $probe_url $"($settings.branch):refs/remotes/($settings.remote)/($settings.branch)"
  ] --allow-failure --quiet --capture --dry-run=$dry_run --environment=(probe-environment) --timeout=(if (remote-url? $probe_url) { 60 } else { 0 }))
  if $fetch.exit_code != 0 {
    return {synced: false status: "inaccessible" detail: ($fetch.stderr | str trim)}
  }
  let tracking = $"refs/remotes/($settings.remote)/($settings.branch)"
  let present = (git-in $root ["rev-parse" "--verify" $tracking])
  if $present.exit_code != 0 {
    return {synced: false status: "missing-branch" detail: $"the remote has no ($settings.branch) branch"}
  }
  run-command git ["-C" ($root | into string) "reset" "--hard" $tracking] --dry-run=$dry_run --quiet | ignore
  {synced: true status: "adopted" detail: $"adopted state from (scrub-url $probe_url)"}
}

# Publish the configured branch to the remote, retrying once when the push
# loses a remote race (the remote moved since our fetch). Pushing to an empty
# remote sets the upstream; a nonempty remote without the configured branch is
# refused rather than guessed.
def push-branch [
  root: path
  settings: record # Configured remote and branch.
  --empty-remote # The remote has no refs yet; set the upstream.
  --dry-run
]: nothing -> record {
  let push_args = ["-C" ($root | into string) "push" $settings.remote $settings.branch]
  if $empty_remote {
    let first = (run-command git ($push_args | append ["--set-upstream"]) --allow-failure --quiet --capture --dry-run=$dry_run)
    if $first.exit_code == 0 { return {ok: true status: "pushed"} }
    return {ok: false status: "push-failed" detail: ($first.stderr | str trim)}
  }
  let first = (run-command git $push_args --allow-failure --quiet --capture --dry-run=$dry_run)
  if $first.exit_code == 0 { return {ok: true status: "pushed"} }
  let stderr = ($first.stderr | str trim)
  if not ($stderr | str contains "fetch first") and not ($stderr | str contains "non-fast-forward") and not ($stderr | str contains "rejected") {
    return {ok: false status: "push-failed" detail: $stderr}
  }
  # Lost a remote race: fetch the moved branch and fast-forward onto it once,
  # then retry the push. A real divergence surfaces instead of being merged
  # silently, so the user resolves it with a sync. The deadline decision uses
  # the remote's resolved URL so local remotes skip the wrapper.
  let raced_url = ((git-in $root ["remote" "get-url" $settings.remote]).stdout | str trim)
  let fetch = (run-command git ["-C" ($root | into string) "-c" "http.lowSpeedLimit=1" "-c" "http.lowSpeedTime=15" "fetch" $settings.remote $settings.branch] --allow-failure --quiet --capture --environment=(probe-environment) --timeout=(if (remote-url? $raced_url) { 60 } else { 0 }))
  if $fetch.exit_code != 0 {
    return {ok: false status: "push-failed" detail: "lost the push race and could not refetch the remote"}
  }
  let ff = (git-in $root ["merge" "--ff-only" $"refs/remotes/($settings.remote)/($settings.branch)"])
  if $ff.exit_code != 0 {
    return {ok: false status: "push-failed" detail: "the remote moved while pushing and the histories diverged; run 'reseed sync' to merge before pushing"}
  }
  let retried = (run-command git $push_args --allow-failure --quiet --capture --dry-run=$dry_run)
  if $retried.exit_code == 0 { return {ok: true status: "pushed"} }
  {ok: false status: "push-failed" detail: ($retried.stderr | str trim)}
}

# Commit dirty working-tree state: print the change summary, scan for
# credential-shaped files, confirm, and commit. Never pushes.
def commit-dirty [
  root: path
  settings: record # Configured remote and branch.
  --yes # Skip the confirmation prompt.
  --dry-run
]: nothing -> record {
  let changes = (commit-change-summary $root)
  if ($changes | is-not-empty) { $changes | table --expand | print }
  let secrets = (scan-commit-secrets $root)
  if ($secrets | is-not-empty) {
    $secrets | table --expand | print
    fail "Sync refused: changed files look like credentials; remove them or exclude them from the private state before committing"
  }
  if not $dry_run and not (confirm "Commit these private-state changes?" --yes=$yes) { return {committed: false} }
  run-command git ["-C" ($root | into string) "add" "--all"] --dry-run=$dry_run --quiet | ignore
  run-command git ["-C" ($root | into string) "commit" "-m" $"Sync (date now | format date '%Y-%m-%d')"] --dry-run=$dry_run --quiet | ignore
  {committed: true}
}

# Rebase the local snapshot history onto a known ancestor (the bundle's
# recorded state_revision) so the recovered snapshot participates in the remote
# history instead of being an unrelated root commit. Handles any linear local
# history that descends from the single import snapshot commit (including
# commits made after the import); only merge histories are declined.
def rebase-snapshot-onto [
  root: path
  ancestor: string # Commit the snapshot is based on.
]: nothing -> bool {
  let merges = (git-in $root ["rev-list" "--merges" "HEAD"])
  if $merges.exit_code != 0 { return false }
  if not ($merges.stdout | str trim | is-empty) { return false }
  let has_ancestor = (git-in $root ["cat-file" "-e" $ancestor])
  if $has_ancestor.exit_code != 0 { return false }
  let rebase = (git-in $root ["rebase" "--onto" $ancestor "--root"])
  $rebase.exit_code == 0
}

# Merge the configured remote branch into the local branch, preserving both
# histories. When there is no shared ancestor (an unknown-base recovered
# snapshot) the complete recovered-snapshot difference is exposed for review
# before an --allow-unrelated-histories merge. When the repository carries
# bundle provenance whose state_revision the remote also contains, that
# revision is preserved as the merge base first. Conflicts persist the merge
# intent so sync --continue / sync --abort can complete or discard the merge.
def merge-remote-branch [
  root: path
  settings: record # Configured remote and branch.
  config: record # Loaded configuration.
  --remote-url: string = "" # Requested remote URL.
  --push # Whether a later push was requested; recorded for sync --continue.
  --yes # Skip the unknown-base confirmation.
  --dry-run
]: nothing -> record {
  let tracking = $"refs/remotes/($settings.remote)/($settings.branch)"
  let base = (git-in $root ["merge-base" "HEAD" $tracking])
  if $base.exit_code != 0 {
    # Unknown base: attach the fetched remote as the baseline and expose the
    # recovered snapshot difference for review before merging.
    let diff = (run-command git ["-C" ($root | into string) "diff" $tracking "HEAD" "--stat"] --allow-failure --quiet --capture)
    if $diff.exit_code == 0 and not ($diff.stdout | str trim | is-empty) {
      info "Recovered snapshot difference against the remote (review before merging):"
      $diff.stdout | print
    } else {
      info "Recovered snapshot matches the remote baseline; no local difference."
    }
    if not $dry_run and not (confirm "Merge the remote baseline with the recovered snapshot (unrelated histories)?" --yes=$yes) {
      return {synced: false status: "unknown-base" detail: "merge declined; the recovered snapshot stays local"}
    }
  }
  let provenance = (import-provenance-load $root $config)
  if $provenance.state_revision? != null {
    let has_ancestor = (git-in $root ["cat-file" "-e" $provenance.state_revision])
    if ($has_ancestor.exit_code == 0) and (rebase-snapshot-onto $root $provenance.state_revision) {
      info $"Preserved bundle provenance: rebased the recovered snapshot onto ($provenance.state_revision)"
    }
  }
  let merge_args = ["-C" ($root | into string) "merge" "-m" $"Merge remote ($settings.branch) into local state" $tracking]
  let merge = (run-command git (if $base.exit_code != 0 { ["-C" ($root | into string) "merge" "--allow-unrelated-histories" "-m" $"Merge remote ($settings.branch) into local state" $tracking] } else { $merge_args }) --allow-failure --quiet --capture --dry-run=$dry_run)
  if $merge.exit_code != 0 {
    if not $dry_run {
      merge-intent-save $root $config {schema: 1 root: ($root | path expand --no-symlink) remote: $settings.remote branch: $settings.branch pushed: $push started_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")}
    }
    return {synced: false status: "conflicts" detail: "the merge has conflicts; resolve them and run 'reseed sync --continue', or run 'reseed sync --abort' to discard the merge"}
  }
  {synced: true status: "merged" detail: $"merged ($settings.branch) into local state"}
}

# Consume a leftover detached-recovery ref: if a previous sync crashed after
# switching to the configured branch but before merging the durable
# refs/reseed/recovered/<branch>, the recovered commits are still outside the
# branch. Merge them now (or clean up a ref that was already merged). Returns a
# status record, or null when there is nothing pending.
def consume-pending-recovery [
  root: path
  settings: record # Configured remote and branch.
  config: record # Loaded configuration.
  --push # Recorded in the merge intent on conflict.
  --yes # Skip confirmations.
  --dry-run
]: nothing -> any {
  let recovery_ref = $"refs/reseed/recovered/($settings.branch)"
  let exists = (git-in $root ["show-ref" "--verify" $recovery_ref])
  if $exists.exit_code != 0 { return null }
  let branch_head = (git-in $root ["rev-parse" "--verify" $"refs/heads/($settings.branch)"])
  if $branch_head.exit_code == 0 {
    let contained = (git-in $root ["merge-base" "--is-ancestor" $recovery_ref $"refs/heads/($settings.branch)"])
    if $contained.exit_code == 0 {
      # The previous sync already merged the commits and crashed before cleanup.
      run-command git ["-C" ($root | into string) "update-ref" "-d" $recovery_ref] --dry-run=$dry_run --quiet | ignore
      info "Consumed a previously merged detached recovery ref"
      return null
    }
  }
  # The branch is missing or lacks the recovered commits: merge them in now.
  let merged = (run-command git ["-C" ($root | into string) "merge" "--no-ff" $recovery_ref "-m" "Preserve recovered detached commits"] --allow-failure --quiet --capture --dry-run=$dry_run)
  if $merged.exit_code != 0 {
    if not $dry_run {
      merge-intent-save $root $config {schema: 1 root: ($root | path expand --no-symlink) remote: $settings.remote branch: $settings.branch pushed: $push recovery_ref: $recovery_ref started_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")}
    }
    return {synced: false status: "conflicts" detail: $"a pending detached recovery merge conflicts with the configured branch; resolve them, then run 'reseed sync --continue' or 'reseed sync --abort'"}
  }
  run-command git ["-C" ($root | into string) "update-ref" "-d" $recovery_ref] --dry-run=$dry_run --quiet | ignore
  info "Preserved recovered commits from an interrupted detached recovery"
  {synced: true status: "merged"}
}

# The default sync operation: safe attachment, fetch, fast-forward, or merge,
# honoring the configured remote and branch names. Never commits dirty state or
# pushes implicitly; --commit commits after review, --push publishes existing
# or newly created commits, and --replace adopts the remote state exactly.
export def repo-sync [
  root: path # Private state root.
  config: record # Loaded configuration.
  --remote-url: string = "" # Requested remote URL (existing origin wins).
  --commit # Commit dirty working-tree state after reviewing changes.
  --push # Publish local (or newly created) commits to the remote.
  --yes # Skip confirmations for commits and merges.
  --replace # Discard local state in favor of the remote (adopt).
  --dry-run
]: nothing -> record {
  let settings = (repo-settings $config)
  # In a dry run the probe must be read-only: it may classify from cached
  # facts but must not fetch, which would mutate objects and remote-tracking
  # refs.
  mut probe: any = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
  let fatal = match $probe.phase {
    no-git => "Git is required to synchronize private state"
    uninitialized => $"private state is not initialized: ($root)"
    merge-in-progress => "an interrupted merge is pending; run 'reseed sync --continue' or 'reseed sync --abort'"
    _ => ""
  }
  if not ($fatal | is-empty) { return {synced: false status: $probe.phase detail: $fatal} }

  if $probe.phase in [no-repo unborn] {
    let adopted = (adopt-remote-state $root $settings $probe --remote-url=$remote_url --dry-run=$dry_run)
    if not $adopted.synced and $adopted.status == "missing-branch" and $probe.phase == "unborn" {
      # An unborn root whose remote lacks the branch: attach and leave the
      # seed; the user can push it or rename the branch.
      return {synced: false status: "missing-branch" detail: ($adopted.detail)}
    }
    return $adopted
  }
  if not $probe.committed { return {synced: false status: "unborn" detail: "the private state has no commits yet"} }
  # Consume a leftover detached-recovery ref from a previous interrupted sync
  # (crash between switching to the branch and merging the recovered commits).
  # The detached handler below re-creates and merges the ref itself, so this
  # only applies when we are already attached.
  if $probe.phase != "detached" {
    let pending = (consume-pending-recovery $root $settings $config --push=$push --yes=$yes --dry-run=$dry_run)
    if $pending != null {
      if not $pending.synced { return $pending }
      $probe = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
    }
  }
  # Attach the effective remote (existing origin, --remote-url, or git.url) to
  # a committed root that has none, so merges and the recommended push target a
  # real remote instead of a name without a URL. After a bundle or raw-snapshot
  # recovery this is what makes the next `sync --push` work.
  if ($probe.remote_url | is-empty) and not (($probe.probe_url? | default "") | is-empty) {
    ensure-remote $root $settings $probe.probe_url --dry-run=$dry_run | ignore
    $probe = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
  }
  if $dry_run {
    # Report the actions a real sync would take without claiming they happened:
    # the phase is reported as-is, so a dry run on a behind repo says "behind",
    # never "synchronized".
    let detail = (match $probe.phase {
      detached => "would reattach to the configured branch and preserve any detached commits"
      shallow => "would deepen the shallow clone"
      dirty => (if $commit { "would review and commit the dirty state" } else { "would report the dirty state" })
      ahead => (if $push { "would push the local commits" } else { "would report the unpushed commits" })
      behind => "would fast-forward the private state"
      diverged => (if $replace { "would adopt the remote state" } else { "would merge the remote branch" })
      unknown-base => "would merge the recovered snapshot with the remote after reviewing the difference"
      empty-remote => (if $push { "would publish the local state to the empty remote" } else { "would report the empty remote" })
      missing-branch => (if $push { "would publish the configured branch to the remote" } else { "would report the missing branch" })
      inaccessible => "would report the remote as unreachable"
      no-remote => "would report that no remote is configured"
      mismatched => "would report the remote mismatch"
      _ => "no changes needed"
    })
    return {synced: ($probe.phase == "clean-synced") status: $probe.phase detail: $"dry run: ($detail)"}
  }
  if $probe.phase == "detached" {
    let head_sha = ((git-in $root ["rev-parse" "HEAD"]).stdout | str trim)
    # A durable reference to the detached commit before any switch, so a crash
    # or an abort never leaves recovered commits reachable only through reflog.
    let recovery_ref = $"refs/reseed/recovered/($settings.branch)"
    run-command git ["-C" ($root | into string) "update-ref" $recovery_ref $head_sha] --dry-run=$dry_run --quiet | ignore
    if not ($probe.clean | default true) {
      return {synced: false status: "dirty" detail: $"the detached HEAD has uncommitted changes; commit or stash them, then rerun sync (the detached commits are preserved at ($recovery_ref))"}
    }
    let has_branch = (git-in $root ["show-ref" "--verify" $"refs/heads/($settings.branch)"])
    if $has_branch.exit_code != 0 {
      # No configured branch yet: create it at the detached HEAD so recovered
      # commits stay reachable.
      run-command git ["-C" ($root | into string) "switch" "-c" $settings.branch] --dry-run=$dry_run --quiet | ignore
      run-command git ["-C" ($root | into string) "update-ref" "-d" $recovery_ref] --dry-run=$dry_run --quiet | ignore
      info $"Created branch '($settings.branch)' at the recovered state"
    } else {
      # The configured branch exists: switch to it, then merge in the detached
      # commits through the durable ref so recovered work is never abandoned.
      run-command git ["-C" ($root | into string) "switch" $settings.branch] --dry-run=$dry_run --quiet | ignore
      let merged = (run-command git ["-C" ($root | into string) "merge" "--no-ff" $recovery_ref "-m" "Preserve recovered detached commits"] --allow-failure --quiet --capture --dry-run=$dry_run)
      if $merged.exit_code != 0 {
        if not $dry_run {
          merge-intent-save $root $config {schema: 1 root: ($root | path expand --no-symlink) remote: $settings.remote branch: $settings.branch pushed: $push recovery_ref: $recovery_ref started_at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")}
        }
        return {synced: false status: "conflicts" detail: $"the detached HEAD holds recovered commits that conflict with the configured branch; resolve them, then run 'reseed sync --continue' or 'reseed sync --abort' (the commits stay preserved at ($recovery_ref))"}
      }
      run-command git ["-C" ($root | into string) "update-ref" "-d" $recovery_ref] --dry-run=$dry_run --quiet | ignore
      info "Preserved recovered commits from the detached HEAD"
    }
    info $"Attached local state to branch '($settings.branch)'"
    $probe = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
  }
  if $probe.phase == "shallow" {
    # Always resolve a shallow repository, not only when it is behind: an
    # up-to-date shallow clone would otherwise stay shallow forever and keep
    # recommending the same sync.
    let unshallow_url = ((git-in $root ["remote" "get-url" $settings.remote]).stdout | str trim)
    let unshallow = (run-command git ["-C" ($root | into string) "fetch" "--unshallow" $settings.remote] --allow-failure --quiet --capture --dry-run=$dry_run --environment=(probe-environment) --timeout=(if (remote-url? $unshallow_url) { 60 } else { 0 }))
    if $unshallow.exit_code != 0 {
      return {synced: false status: "inaccessible" detail: "could not deepen the shallow clone; the remote may be unreachable"}
    }
    $probe = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
  }
  if $probe.phase == "inaccessible" { return {synced: false status: "inaccessible" detail: "the remote repository cannot be reached"} }
  if $probe.phase == "no-remote" { return {synced: false status: "no-remote" detail: "no remote repository is configured; pass --remote-url or set git.url"} }
  if $probe.phase == "mismatched" { return {synced: false status: "mismatched" detail: "the configured remote points elsewhere; pass the matching --remote-url or fix git.url"} }
  if $probe.phase == "missing-branch" {
    if $push {
      # Publishing the configured branch by its explicit name is not guessing;
      # it creates the branch on the remote.
      let pushed = (push-branch $root $settings --dry-run=$dry_run)
      if not $pushed.ok { return {synced: false status: "push-failed" detail: $pushed.detail} }
      return {synced: true status: "pushed" detail: "published the configured branch to the remote"}
    }
    return {synced: false status: "missing-branch" detail: $"the remote has no ($settings.branch) branch; run with --push to publish the configured branch explicitly"}
  }
  if $probe.phase == "offline-unknown" {
    return {synced: false status: "offline-unknown" detail: "the remote state could not be verified; run sync without --offline"}
  }

  let tracking = $"refs/remotes/($settings.remote)/($settings.branch)"
  if $probe.phase == "empty-remote" {
    if not $push {
      return {synced: false status: "empty-remote" detail: "the remote is empty; run with --push to publish the local state"}
    }
    let pushed = (push-branch $root $settings --empty-remote --dry-run=$dry_run)
    if not $pushed.ok { return {synced: false status: "push-failed" detail: $pushed.detail} }
    return {synced: true status: "pushed" detail: "published the local state to the empty remote"}
  }

  if $probe.phase == "unknown-base" {
    return (finish-merge-result $root $settings (merge-remote-branch $root $settings $config --remote-url=$remote_url --push=$push --yes=$yes --dry-run=$dry_run) $push --dry-run=$dry_run)
  }

  if $probe.phase == "dirty" {
    if $replace and ($probe.remote.reachable == true) and ($probe.remote.has_branch == true) {
      run-command git ["-C" ($root | into string) "reset" "--hard" $tracking] --dry-run=$dry_run --quiet | ignore
      warning "Discarded local private-state changes in favor of the remote state"
      return {synced: true status: "replaced"}
    }
    if not $commit {
      return {synced: false status: "dirty" detail: "the private state has uncommitted changes; run with --commit to review and commit them"}
    }
    let committed = (commit-dirty $root $settings --yes=$yes --dry-run=$dry_run)
    if not $committed.committed { return {synced: false status: "dirty" detail: "the private-state changes were not committed"} }
    $probe = (repo-probe $root $config --remote-url=$remote_url --read-only=$dry_run)
  }

  if $probe.phase == "unknown-base" {
    return (finish-merge-result $root $settings (merge-remote-branch $root $settings $config --remote-url=$remote_url --push=$push --yes=$yes --dry-run=$dry_run) $push --dry-run=$dry_run)
  }

  if $probe.phase == "diverged" {
    if $replace {
      run-command git ["-C" ($root | into string) "reset" "--hard" $tracking] --dry-run=$dry_run --quiet | ignore
      warning "Discarded local private-state commits in favor of the remote state"
      return {synced: true status: "replaced"}
    }
    return (finish-merge-result $root $settings (merge-remote-branch $root $settings $config --remote-url=$remote_url --push=$push --yes=$yes --dry-run=$dry_run) $push --dry-run=$dry_run)
  }

  if ($probe.behind != null) and ($probe.behind > 0) {
    if ($probe.ahead != null) and ($probe.ahead > 0) {
      return (finish-merge-result $root $settings (merge-remote-branch $root $settings $config --remote-url=$remote_url --push=$push --yes=$yes --dry-run=$dry_run) $push --dry-run=$dry_run)
    }
    let ff = (run-command git ["-C" ($root | into string) "merge" "--ff-only" $tracking] --allow-failure --quiet --capture --dry-run=$dry_run)
    if $ff.exit_code != 0 {
      return (finish-merge-result $root $settings (merge-remote-branch $root $settings $config --remote-url=$remote_url --push=$push --yes=$yes --dry-run=$dry_run) $push --dry-run=$dry_run)
    }
    info $"Fast-forwarded private state to the remote ($settings.branch)"
  }

  if $push and (($probe.ahead != null) and ($probe.ahead > 0) or ($probe.phase == "ahead")) {
    let pushed = (push-branch $root $settings --dry-run=$dry_run)
    if not $pushed.ok { return {synced: false status: "push-failed" detail: $pushed.detail} }
    return {synced: true status: "pushed" detail: "published local commits to the remote"}
  }
  if ($probe.ahead != null) and ($probe.ahead > 0) {
    return {synced: false status: "ahead" detail: $"the private state is ($probe.ahead) commits ahead of the remote; run with --push to publish them"}
  }
  {synced: true status: "synced" detail: "private state is synchronized with the remote"}
}

# Complete an interrupted merge: validate that conflicts were resolved, finish
# the merge, honor the requested push, and clear the intent.
export def repo-merge-continue [
  root: path # Private state root.
  config: record # Loaded configuration.
  --push # Publish the merge (or any pending commits) afterwards.
  --yes # Skip confirmations.
  --dry-run
]: nothing -> record {
  let intent = (merge-intent-load $root $config)
  if $intent == null { return {synced: false status: "no-merge" detail: "no interrupted merge is recorded for this state root"} }
  let settings = (repo-settings $config)
  let probe = (repo-probe $root $config)
  if not $probe.merge_in_progress {
    warning "No merge is in progress; clearing the stale merge intent"
    merge-intent-clear $root $config
    return {synced: true status: "completed" detail: "no merge was in progress"}
  }
  let unmerged = (run-command git ["-C" ($root | into string) "ls-files" "--unmerged"] --allow-failure --quiet --capture)
  if not ($unmerged.stdout | str trim | is-empty) {
    return {synced: false status: "conflicts" detail: "merge conflicts remain; resolve them, stage the resolved files, then rerun sync --continue"}
  }
  # Conflict markers must be gone from the working tree AND the index: a file
  # that was `git add`-ed with markers still present would otherwise pass an
  # unstaged-only check and be committed.
  let worktree_check = (git-in $root ["diff" "--check"])
  if $worktree_check.exit_code != 0 {
    return {synced: false status: "conflicts" detail: "conflict markers remain in the working tree; resolve them before continuing"}
  }
  let staged_check = (git-in $root ["diff" "--cached" "--check"])
  if $staged_check.exit_code != 0 {
    return {synced: false status: "conflicts" detail: "staged files still contain conflict markers; resolve them before continuing"}
  }
  let commit = (run-command git ["-C" ($root | into string) "commit" "--no-edit"] --allow-failure --quiet --capture --dry-run=$dry_run)
  if $commit.exit_code != 0 {
    return {synced: false status: "conflicts" detail: $"could not complete the merge: ($commit.stderr | str trim)"}
  }
  # Only mutate the merge metadata once the real merge commit exists.
  if not $dry_run {
    if ($intent.recovery_ref? | default "") != "" {
      run-command git ["-C" ($root | into string) "update-ref" "-d" $intent.recovery_ref] --quiet | ignore
    }
    merge-intent-clear $root $config
  }
  if $push or ($intent.pushed? | default false) {
    let pushed = (push-branch $root $settings --dry-run=$dry_run)
    if not $pushed.ok { return {synced: false status: "push-failed" detail: $pushed.detail} }
  }
  {synced: true status: "completed" detail: "merge completed"}
}

# Discard an interrupted merge and restore the pre-merge state. A recovery ref
# recorded in the merge intent is deliberately kept: it is the durable pointer
# to recovered detached commits, so aborting never strands them. The merge
# intent is only cleared after the abort succeeds, so a failed abort keeps the
# metadata needed to continue or retry.
export def repo-merge-abort [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run
]: nothing -> record {
  let intent = (merge-intent-load $root $config)
  let recovery_ref = ($intent.recovery_ref? | default "")
  let probe = (repo-probe $root $config)
  if not $probe.merge_in_progress {
    warning "No merge is in progress; nothing to abort"
    return {synced: true status: "aborted" detail: "nothing to abort"}
  }
  let aborted = (run-command git ["-C" ($root | into string) "merge" "--abort"] --allow-failure --quiet --capture --dry-run=$dry_run)
  if $aborted.exit_code != 0 {
    return {synced: false status: "abort-failed" detail: $"could not abort the merge: ($aborted.stderr | str trim)"}
  }
  if not $dry_run and $intent != null { merge-intent-clear $root $config }
  let detail = if ($recovery_ref | is-empty) {
    "merge aborted; the pre-merge state was restored"
  } else {
    $"merge aborted; the pre-merge state was restored and the recovered commits stay preserved at ($recovery_ref)"
  }
  {synced: true status: "aborted" detail: $detail}
}

# Path of the disposable import record for a destination root.
export def import-record-path [root: path, config: record]: nothing -> path {
  let key = (repo-key $root)
  repo-state-dir $config | path join "imports" $"($key).nuon"
}

# Load the import record for a destination root, or null.
export def import-record-load [root: path, config: record]: nothing -> any {
  let path = (import-record-path $root $config)
  if not ($path | path exists) { return null }
  open $path
}

# Load the import provenance for a repository (bundle state_revision, kind),
# or null when the state was not imported from a provenance-bearing source.
export def import-provenance-load [root: path, config: record]: nothing -> any {
  let record = (import-record-load $root $config)
  if $record == null { return null }
  if ($record.schema? | default 0) != 1 { return null }
  {source: ($record.source? | default "") kind: ($record.kind? | default "") state_revision: ($record.state_revision? | default "")}
}

# Publish the configured branch to the remote with the same race retry used by
# sync. Returns {ok, status, detail}.
export def repo-push [
  root: path # Private state root.
  config: record # Loaded configuration.
  --dry-run
]: nothing -> record {
  let settings = (repo-settings $config)
  push-branch $root $settings --dry-run=$dry_run
}

# Finish a sync that merged: publish when --push was requested, otherwise
# report the merge itself.
def finish-merge-result [
  root: path # Private state root.
  settings: record # Configured remote and branch.
  merged: record # The merge outcome.
  push: bool # Whether a push was requested.
  --dry-run
]: nothing -> record {
  if not $merged.synced { return $merged }
  if $push {
    let pushed = (push-branch $root $settings --dry-run=$dry_run)
    if not $pushed.ok { return {synced: false status: "push-failed" detail: $pushed.detail} }
    return {synced: true status: "pushed" detail: "merged and published local commits to the remote"}
  }
  $merged
}

# Conservative repository refresh used by the bootstrap (`sync-state`) and by
# adopt: fast-forward an already-initialized root from the provided
# repository, adopt an unborn or sentinel-only root wholesale, and leave dirty
# or diverged roots alone unless --replace discards local work. Returns a
# {synced, status} record so callers can report why a refresh was skipped.
export def repo-refresh [
  root: path # Private state root.
  config: record # Loaded configuration.
  repository: string # Private state repository URL.
  --replace # Discard local commits and uncommitted changes.
  --dry-run
]: nothing -> record {
  let settings = (repo-settings $config)
  let probe = (repo-probe $root $config --remote-url=$repository)
  match $probe.phase {
    no-git => (fail "Git is required to refresh the private state")
    uninitialized => {warning "Private state is not initialized; leaving it unchanged"; {synced: false status: "no-repo"}}
    no-repo => (adopt-remote-state $root $settings $probe --remote-url=$repository --dry-run=$dry_run)
    unborn => (adopt-remote-state $root $settings $probe --remote-url=$repository --dry-run=$dry_run)
    merge-in-progress => (fail "An interrupted merge is pending; run 'reseed sync --continue' or 'reseed sync --abort'")
    detached => {warning "Private state has a detached HEAD; leaving it unchanged"; {synced: false status: "detached"}}
    shallow => {warning "Private state is a shallow clone; leaving it unchanged"; {synced: false status: "shallow"}}
    inaccessible => (fail $"Cannot read the private state repository: (scrub-url $repository)")
    mismatched => (fail $"Git remote '($settings.remote)' points elsewhere; refusing to sync from (scrub-url $repository)")
    missing-branch => (fail $"The private state repository has no ($settings.branch) branch: (scrub-url $repository)")
    empty-remote => {info "The remote repository is empty; leaving local state unchanged"; {synced: true status: "attached"}}
    dirty => {
      if $replace {
        run-command git ["-C" ($root | into string) "reset" "--hard" $"refs/remotes/($settings.remote)/($settings.branch)"] --dry-run=$dry_run --quiet | ignore
        warning "Discarded local private-state changes in favor of the provided state"
        {synced: true status: "replaced"}
      } else {
        warning "Private state has local changes; leaving it unchanged"
        {synced: false status: "dirty"}
      }
    }
    diverged => {
      if $replace {
        run-command git ["-C" ($root | into string) "reset" "--hard" $"refs/remotes/($settings.remote)/($settings.branch)"] --dry-run=$dry_run --quiet | ignore
        warning "Discarded local private-state commits in favor of the provided state"
        {synced: true status: "replaced"}
      } else {
        warning "Private state has diverged from the repository; leaving it unchanged"
        {synced: false status: "diverged"}
      }
    }
    unknown-base => {
      warning "The local snapshot shares no history with the repository; leaving it unchanged"
      {synced: false status: "diverged"}
    }
    ahead => {
      if $replace {
        run-command git ["-C" ($root | into string) "reset" "--hard" $"refs/remotes/($settings.remote)/($settings.branch)"] --dry-run=$dry_run --quiet | ignore
        warning "Discarded local private-state commits ahead of the repository"
        {synced: true status: "replaced"}
      } else {
        warning "Local private state is ahead of the repository; leaving local commits in place; push them with 'reseed sync --push'"
        {synced: true status: "ahead"}
      }
    }
    behind => {
      let ff = (run-command git ["-C" ($root | into string) "merge" "--ff-only" $"refs/remotes/($settings.remote)/($settings.branch)"] --allow-failure --quiet --capture --dry-run=$dry_run)
      if $ff.exit_code != 0 { fail $"Could not fast-forward private state: ($ff.stderr | str trim)" }
      info "Synchronized private state"
      {synced: true status: "synced"}
    }
    _ => {synced: true status: "synced"}
  }
}

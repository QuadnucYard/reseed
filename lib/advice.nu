# The prioritized recommendation layer for `reseed status` and for reuse after
# successful commands and before actionable failures.
#
# `recommend` is pure: it turns the machine readable repository facts plus a
# small context record into an ordered list of copy-pasteable commands. The
# ordering is fixed: resolve or abort conflicts, import or repair state,
# install prerequisites, restore the current fingerprint, configure repository
# access, attach/commit/merge/push state, then report synchronized completion.

use core.nu [detect-os show-command]

# Render "nu <engine>/reseed.nu <subcommand> [purpose] --flags" with exact
# quoting and redacted URLs. Extra positional args (such as a setup purpose)
# come immediately after the subcommand, before the flags.
def reseed-command [
  context: record # Engine root, profiles, and known remote URL.
  facts: record # Status facts; supplies the state root.
  subcommand: string # Reseed subcommand to suggest.
  extra: list<string> = [] # Positional arguments and additional flags.
]: nothing -> string {
  let script = ($context.engine_root | path join "reseed.nu")
  mut args = [($script | into string) $subcommand]
  $args = ($args | append $extra)
  $args = ($args | append ["--state-root" ($facts.state_root | into string)])
  let profiles = ($context.profiles? | default [] | where {|p| not ($p | is-empty) })
  if ($profiles | is-not-empty) {
    $args = ($args | append ["--profiles" ($profiles | str join ",")])
  }
  show-command "nu" $args
}

# Known remote URL for rendering, preferring the configured origin and falling
# back to the context's git.url value.
def known-remote [facts: record, context: record]: nothing -> string {
  if not ($facts.remote_url? | default "" | is-empty) { $facts.remote_url } else { $context.remote_url? | default "" }
}

# The platform-specific Git install command.
def git-install-command []: nothing -> string {
  match (detect-os) {
    windows => (show-command "winget" ["install" "--id" "Git.Git" "--exact" "--accept-source-agreements" "--accept-package-agreements"])
    macos => (show-command "brew" ["install" "git"])
    _ => "install git through your system package manager"
  }
}

# Blocking recommendations: these phases must be resolved before the recovery
# progression (restore, setup, sync) is meaningful.
def blocking-recommendations [
  facts: record
  context: record
]: nothing -> list<record> {
  let remote = (known-remote $facts $context)
  if $facts.phase == "merge-in-progress" {
    return [
      {
        priority: 1
        phase: merge-in-progress
        title: "Complete the merge after resolving and staging the conflicts, or discard it"
        commands: [
          (reseed-command $context $facts "sync" ["--continue"])
          (reseed-command $context $facts "sync" ["--abort"])
        ]
      }
    ]
  }
  if $facts.phase == "no-git" {
    return [{priority: 3 phase: no-git title: "Install Git" commands: [(git-install-command)]}]
  }
  if $facts.phase in [uninitialized no-repo] or not ($facts.config_ok? | default true) {
    # Import the downloaded state directly: the recovered snapshot is the
    # authoritative state and must not be contaminated by a template seed, so
    # `init` is only offered as the no-source fallback after it.
    let commands = [
      (reseed-command $context $facts "restore" ["--state-source" "<downloaded-state>"])
      (reseed-command $context $facts "init")
    ]
    let title = if $facts.phase == "uninitialized" { "Initialize the private state" } else { "Repair the private state" }
    return [{priority: 2 phase: import title: $title commands: $commands}]
  }
  if $facts.phase == "unborn" {
    let commands = if ($remote | is-empty) {
      [
        (reseed-command $context $facts "restore" ["--state-source" "<downloaded-state>"])
        (reseed-command $context $facts "init")
      ]
    } else {
      [
        (reseed-command $context $facts "sync" ["--remote-url" $remote])
        (reseed-command $context $facts "restore" ["--state-source" "<downloaded-state>"])
      ]
    }
    return [{priority: 2 phase: import title: "Commit or adopt the template seed" commands: $commands}]
  }
  []
}

# The recovery progression: restore the current fingerprint, configure
# repository access, attach/commit/merge/push state, then report completion.
def progression-recommendations [
  facts: record
  context: record
]: nothing -> list<record> {
  let remote = (known-remote $facts $context)
  mut out = []
  if ($facts.config_ok? | default true) and $facts.committed and not ($facts.restored? | default false) {
    $out = ($out | append {
      priority: 4
      phase: restore
      title: "Restore the machine to the current desired state"
      commands: [(reseed-command $context $facts "restore")]
    })
  }
  let access_phases = [no-remote inaccessible mismatched missing-branch offline-unknown]
  if $facts.phase in $access_phases {
    let commands = match $facts.phase {
      no-remote => (if ($remote | is-empty) {
        # No repository URL is known anywhere; recommend configuring one via
        # the setup wizard and attaching it by placeholder.
        [(reseed-command $context $facts "setup" ["gh"]) (reseed-command $context $facts "sync" ["--remote-url" "<private-state-url>"])]
      } else {
        [(reseed-command $context $facts "setup" ["gh"]) (reseed-command $context $facts "sync" ["--remote-url" $remote])]
      })
      inaccessible => [(reseed-command $context $facts "setup" ["gh"]) (reseed-command $context $facts "sync")]
      mismatched => [(reseed-command $context $facts "sync" ["--remote-url" $remote])]
      missing-branch => [(reseed-command $context $facts "sync" ["--push"])]
      _ => [(reseed-command $context $facts "sync")]
    }
    $out = ($out | append {priority: 5 phase: access title: "Configure repository access" commands: $commands})
  }
  let sync_phases = [behind ahead diverged dirty empty-remote detached shallow unknown-base]
  if $facts.phase in $sync_phases or $facts.phase in $access_phases {
    let command = match $facts.phase {
      ahead => (reseed-command $context $facts "sync" ["--push"])
      dirty => (reseed-command $context $facts "sync" ["--commit" "--push"])
      empty-remote => (reseed-command $context $facts "sync" ["--push"])
      _ => (reseed-command $context $facts "sync")
    }
    $out = ($out | append {priority: 6 phase: sync title: "Synchronize private state" commands: [$command]})
  }
  if $facts.phase == "clean-synced" and ($facts.restored? | default false) {
    $out = ($out | append {priority: 7 phase: complete title: "Private state is synchronized" commands: []})
  }
  $out
}

# The prioritized recommendations for a set of status facts.
export def recommend [
  facts: record # Repository probe facts plus config_ok and restored flags.
  context: record # Engine root, profiles, and known remote URL.
]: nothing -> list<record> {
  let blocking = (blocking-recommendations $facts $context)
  if ($blocking | is-not-empty) { return $blocking }
  progression-recommendations $facts $context
}

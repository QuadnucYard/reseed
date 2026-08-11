# Setup purpose planning: step metadata, purpose selection, transitive
# dependency closure, stable ordering, and optional feature gating.

use ../core.nu [command-exists fail]
use ./shared.nu [ask-default-yes]
use ./provider.nu [parse-repo-url provider-descriptor]

# Ordered step metadata: dependency closure drives the plan, features gate
# the optional areas (gpg, jj), and definition order is the stable run order.
def setup-step-defs []: nothing -> list<record> {
  [
    {step: jj-prereq depends_on: [] features: [jj]}
    {step: identity depends_on: [jj-prereq] features: []}
    {step: gh-auth depends_on: [] features: []}
    {step: ssh-key depends_on: [identity] features: []}
    {step: ssh-agent depends_on: [ssh-key] features: []}
    {step: ssh-github depends_on: [gh-auth ssh-key] features: []}
    {step: ssh-hosts depends_on: [ssh-key] features: []}
    {step: ssh-config depends_on: [ssh-hosts] features: []}
    {step: ssh-test depends_on: [ssh-hosts] features: []}
    {step: gh-credential-helper depends_on: [gh-auth] features: []}
    {step: gh-repo-probe depends_on: [identity] features: []}
    {step: gpg-prereq depends_on: [] features: [gpg]}
    {step: gpg-key depends_on: [identity gpg-prereq] features: [gpg]}
    {step: gpg-github depends_on: [gh-auth gpg-key] features: [gpg]}
    {step: gpg-git depends_on: [gpg-key] features: [gpg]}
    {step: gpg-jj depends_on: [gpg-key jj-prereq] features: [gpg jj]}
    {step: gpg-verify depends_on: [gpg-git] features: [gpg]}
  ]
}

# Whether the repository belongs to the GitHub provider (the gh CLI owns its
# uploads). An empty URL keeps the legacy GitHub default.
def gh-cli-provider? [repo_url: string]: nothing -> bool {
  if ($repo_url | str trim | is-empty) { return true }
  (provider-descriptor (parse-repo-url $repo_url).provider).gh_cli
}

# The GPG signing steps for a repository: the GitHub GPG-key upload only makes
# sense for GitHub repositories.
def gpg-steps [repo_url: string]: nothing -> list<string> {
  if (gh-cli-provider? $repo_url) {
    [gpg-prereq gpg-key gpg-github gpg-git gpg-jj gpg-verify]
  } else {
    [gpg-prereq gpg-key gpg-git gpg-jj gpg-verify]
  }
}

# The all purpose: the union of the provider-aware gh subplan, the generic SSH
# host steps, and the GPG steps. GitHub-specific upload steps (gh auth, GitHub
# key uploads) only appear for GitHub repositories, so a default `reseed setup`
# never authenticates with or uploads to GitHub for a GitLab or generic host.
def all-purpose-steps [repo_url: string]: nothing -> list<string> {
  ((gh-purpose-steps $repo_url) | append [ssh-key ssh-agent ssh-hosts ssh-config ssh-test] | append (gpg-steps $repo_url) | uniq)
}

# Steps each purpose selects; missing dependencies are added automatically.
def setup-purpose-steps [purpose: string, repo_url: string]: nothing -> list<string> {
  match $purpose {
    identity => [identity]
    ssh-local => [identity ssh-key ssh-agent]
    ssh-remote => [identity ssh-key ssh-hosts ssh-config]
    ssh => [identity ssh-key ssh-agent ssh-hosts ssh-config ssh-test]
    gh => (gh-purpose-steps $repo_url)
    gpg => ([identity] | append (gpg-steps $repo_url))
    all => (all-purpose-steps $repo_url)
    _ => (fail $"Unknown setup purpose: ($purpose)")
  }
}

# The gh purpose steps for a repository URL, routed by provider and transport
# through the data-driven provider descriptors. GitHub URLs use the gh CLI
# (auth, key upload, credential helper, probing); other Git hosts skip gh and
# run the generic transport check.
def gh-purpose-steps [repo_url: string]: nothing -> list<string> {
  if ($repo_url | str trim | is-empty) { return [identity gh-auth ssh-key ssh-github] }
  let parsed = (parse-repo-url $repo_url)
  let descriptor = (provider-descriptor $parsed.provider)
  if $descriptor.gh_cli {
    if $parsed.transport == "ssh" { [identity gh-auth ssh-key ssh-github] } else { [identity gh-auth gh-credential-helper gh-repo-probe] }
  } else {
    if $parsed.transport == "ssh" { [identity ssh-key gh-repo-probe] } else { [identity gh-repo-probe] }
  }
}

# Expand a step list with its transitive dependencies.
def step-closure [wanted: list<string>]: nothing -> list<string> {
  let defs = (setup-step-defs)
  mut expanded = ($wanted | uniq)
  loop {
    let added = ($expanded
      | each {|name| ($defs | where step == $name | first).depends_on }
      | flatten
      | where {|dep| $dep not-in $expanded })
    if ($added | is-empty) { break }
    $expanded = ($expanded | append $added)
  }
  $expanded
}

# Stable topological order of a step set: repeatedly take the first step in
# definition order whose dependencies are already ordered.
def step-order [steps: list<string>]: nothing -> list<string> {
  let defs = (setup-step-defs)
  mut ordered = []
  mut remaining = $steps
  while ($remaining | is-not-empty) {
    let next = ($defs
      | where {|d| ($d.step in $remaining) and (($d.depends_on | where {|dep| $dep in $remaining }) | is-empty) }
      | first).step
    $ordered = ($ordered | append $next)
    $remaining = ($remaining | where {|s| $s != $next })
  }
  $ordered
}

# The ordered plan for a purpose: transitive dependencies, feature-gated,
# numbered from 1.
export def setup-plan [
  purpose: string # Setup purpose: identity, ssh, ssh-local, ssh-remote, gh, gpg, or all.
  --jj = true # Include jj-dependent steps.
  --gpg = true # Include GPG signing steps.
  --repo-url: string = "" # Private state repository URL; makes the gh purpose protocol-aware.
]: nothing -> list<record> {
  let defs = (setup-step-defs)
  (step-order (step-closure (setup-purpose-steps $purpose $repo_url)))
    | each {|name| $defs | where step == $name | first }
    | where {|d| ($d.features | all {|feature| if $feature == gpg { $gpg } else if $feature == jj { $jj } else { true } }) }
    | enumerate
    | each {|entry| {order: ($entry.index + 1) step: $entry.item.step depends_on: $entry.item.depends_on}}
}

# Detect the optional features and ask about missing ones. jj and GPG default
# to enabled; --no-gpg/--no-jj force them off without asking.
export def resolve-setup-features [
  --yes # Apply defaults without prompting.
  --no-gpg # Disable the GPG signing area.
  --no-jj # Disable the jj area.
]: nothing -> record {
  let gpg_present = (command-exists gpg)
  let jj_present = (command-exists jj)
  let gpg = if $no_gpg {
    false
  } else if $gpg_present {
    true
  } else if $yes {
    true
  } else {
    ask-default-yes "GPG signing setup (installs GnuPG) is available; enable it?"
  }
  let jj = if $no_jj {
    false
  } else if $jj_present {
    true
  } else if $yes {
    true
  } else {
    ask-default-yes "jujutsu (jj) is not installed; install it?"
  }
  {gpg: $gpg jj: $jj gpg_present: $gpg_present jj_present: $jj_present}
}

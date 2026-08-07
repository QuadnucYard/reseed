# Setup purpose planning: step metadata, purpose selection, transitive
# dependency closure, stable ordering, and optional feature gating.

use ../core.nu [command-exists fail]
use ./shared.nu [ask-default-yes]

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
    {step: gpg-prereq depends_on: [] features: [gpg]}
    {step: gpg-key depends_on: [identity gpg-prereq] features: [gpg]}
    {step: gpg-github depends_on: [gh-auth gpg-key] features: [gpg]}
    {step: gpg-git depends_on: [gpg-key] features: [gpg]}
    {step: gpg-jj depends_on: [gpg-key jj-prereq] features: [gpg jj]}
    {step: gpg-verify depends_on: [gpg-git] features: [gpg]}
  ]
}

# Steps each purpose selects; missing dependencies are added automatically.
def setup-purpose-steps [purpose: string]: nothing -> list<string> {
  match $purpose {
    identity => [identity]
    ssh-local => [identity ssh-key ssh-agent]
    ssh-remote => [identity ssh-key ssh-hosts ssh-config]
    ssh => [identity ssh-key ssh-agent ssh-hosts ssh-config ssh-test]
    gh => [identity gh-auth ssh-key ssh-github]
    gpg => [identity gpg-prereq gpg-key gpg-github gpg-git gpg-jj gpg-verify]
    all => (setup-step-defs | get step)
    _ => (fail $"Unknown setup purpose: ($purpose)")
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
]: nothing -> list<record> {
  let defs = (setup-step-defs)
  (step-order (step-closure (setup-purpose-steps $purpose)))
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

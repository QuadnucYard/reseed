use core.nu [fail require-file]

export def deep-merge [base: record overlay: record]: nothing -> record {
  mut result = $base
  for entry in ($overlay | transpose key value) {
    let current = ($result | get -o $entry.key)
    let current_kind = if $current == null { "nothing" } else { $current | describe }
    let overlay_kind = ($entry.value | describe)
    let value = if ($current_kind | str starts-with "record") and ($overlay_kind | str starts-with "record") {
      deep-merge $current $entry.value
    } else {
      $entry.value
    }
    $result = ($result | upsert $entry.key $value)
  }
  $result
}

export def parse-profiles [profiles: string]: nothing -> list<string> {
  if ($profiles | str trim | is-empty) {
    []
  } else {
    $profiles | split row "," | each {|name| $name | str trim } | where {|name| not ($name | is-empty) }
  }
}

export def load-config [root: path profiles: list<string> = []]: nothing -> record {
  let base_path = ($root | path join "config" "recovery.nuon")
  require-file $base_path "base configuration"
  mut config = (open $base_path)
  if ($config | describe) !~ '^record' {
    fail $"Base configuration must be a NUON record: ($base_path)"
  }
  if ($config.schema? | default 0) != 1 {
    fail $"Unsupported configuration schema: ($config.schema? | default 'missing')"
  }

  let selected = if ($profiles | is-empty) {
    $config.default_profiles? | default []
  } else {
    $profiles
  }

  for profile in $selected {
    if $profile !~ '^[A-Za-z0-9][A-Za-z0-9_-]*$' {
      fail $"Invalid profile name: ($profile)"
    }
    let profile_path = ($root | path join "config" "profiles" $"($profile).nuon")
    require-file $profile_path $"profile '($profile)'"
    let overlay = (open $profile_path)
    if ($overlay | describe) !~ '^record' {
      fail $"Profile must contain a NUON record: ($profile_path)"
    }
    $config = (deep-merge $config $overlay)
  }

  $config | upsert active_profiles $selected
}

export def validate-config [root: path config: record]: nothing -> list<record> {
  mut issues = []
  if not (($root | path join ".reseed-state") | path exists) {
    $issues = ($issues | append {level: error area: state message: "Private state is missing .reseed-state"})
  }
  let software = ($config.software? | default {})
  for manager in [winget homebrew mise] {
    let settings = ($software | get -o $manager | default {})
    if ($settings.enabled? | default false) {
      let key = if $manager == "mise" { "configs" } else { "manifests" }
      for relative in ($settings | get -o $key | default []) {
        let target = ($root | path join $relative)
        if not ($target | path exists) {
          $issues = ($issues | append {level: error area: $manager message: $"Missing desired-state file: ($relative)"})
        }
        if $manager == "mise" {
          let name = ($target | path basename)
          if ($name != "mise.toml") and ($name !~ '^mise\.[A-Za-z0-9_-]+\.toml$') {
            $issues = ($issues | append {level: error area: mise message: $"Unsupported config name: ($relative); use mise.toml or mise.<environment>.toml"})
          }
        }
      }
      if $manager == "mise" {
        for relative in ($settings.task_files? | default []) {
          if not (($root | path join $relative) | path exists) {
            $issues = ($issues | append {level: error area: mise message: $"Missing mise task file: ($relative)"})
          }
        }
      }
    }
  }

  if ($config.chezmoi.enabled? | default false) and not (($root | path join ".chezmoiroot") | path exists) {
    $issues = ($issues | append {level: error area: chezmoi message: "The source is missing .chezmoiroot"})
  }
  $issues
}

export def config-fingerprint [root: path config: record --engine-root: path]: nothing -> string {
  mut files = [($root | path join "config" "recovery.nuon") ($root | path join ".chezmoiroot")]
  for profile in ($config.active_profiles? | default []) {
    $files = ($files | append ($root | path join "config" "profiles" $"($profile).nuon"))
  }
  let software = ($config.software? | default {})
  for manager in [winget homebrew mise] {
    let settings = ($software | get -o $manager | default {})
    let key = if $manager == "mise" { "configs" } else { "manifests" }
    for relative in ($settings | get -o $key | default []) {
      $files = ($files | append ($root | path join $relative))
    }
    if $manager == "mise" {
      for relative in ($settings.task_files? | default []) {
        $files = ($files | append ($root | path join $relative))
      }
    }
  }
  let home_root = ($root | path join "home")
  if ($home_root | path exists) {
    let home_files = (do { cd $home_root; glob **/* --no-dir })
    $files = ($files | append $home_files)
  }
  if $engine_root != null {
    $files = ($files | append [
      ($engine_root | path join "reseed.nu")
      ($engine_root | path join "bootstrap.ps1")
      ($engine_root | path join "bootstrap.sh")
    ])
    for directory in [lib integrations] {
      let path = ($engine_root | path join $directory)
      if ($path | path exists) {
        let engine_files = (do { cd $path; glob **/* --no-dir })
        $files = ($files | append $engine_files)
      }
    }
  }

  let content = ($files
    | uniq
    | sort
    | where {|path| $path | path exists }
    | each {|path| $"($path):((open --raw $path | hash sha256))" }
    | str join "\n")
  $"($config | to nuon)\n($content)" | hash sha256
}

use core.nu [expand-home now-string]

export def state-root [config: record]: nothing -> path {
  expand-home ($config.state_dir? | default "~/.local/state/reseed")
}

export def checkpoint-path [config: record]: nothing -> path {
  let profiles = ($config.active_profiles? | default [default] | str join "-")
  let safe = ($profiles | str replace --all --regex '[^A-Za-z0-9_-]' '_')
  state-root $config | path join "checkpoints" $"restore-($nu.os-info.name)-($safe).nuon"
}

export def load-checkpoint [root: path config: record fingerprint: string --resume]: nothing -> record {
  let path = (checkpoint-path $config)
  if $resume and ($path | path exists) {
    let value = (open $path)
    if ($value.root? | default "") != ($root | path expand --no-symlink) {
      error make {msg: $"Checkpoint belongs to another source: ($value.root? | default 'unknown')"}
    }
    if ($value.fingerprint? | default "") != $fingerprint {
      error make {msg: "Desired state changed since this checkpoint; start a new restore without --resume"}
    }
    $value
  } else {
    {
      schema: 1
      root: ($root | path expand --no-symlink)
      profiles: ($config.active_profiles? | default [])
      fingerprint: $fingerprint
      completed: []
      failed: null
      started_at: (now-string)
      updated_at: (now-string)
    }
  }
}

export def save-checkpoint [config: record checkpoint: record] {
  let path = (checkpoint-path $config)
  mkdir ($path | path dirname)
  $checkpoint | upsert updated_at (now-string) | to nuon --indent 2 | save --force $path
}

export def stage-done [checkpoint: record stage: string]: nothing -> bool {
  $stage in ($checkpoint.completed? | default [])
}

export def complete-stage [config: record checkpoint: record stage: string --dry-run]: nothing -> record {
  let updated = ($checkpoint
    | upsert completed (($checkpoint.completed? | default []) | append $stage | uniq)
    | upsert failed null)
  if not $dry_run { save-checkpoint $config $updated }
  $updated
}

export def fail-stage [config: record checkpoint: record stage: string message: string --dry-run]: nothing -> record {
  let updated = ($checkpoint | upsert failed {stage: $stage message: $message at: (now-string)})
  if not $dry_run { save-checkpoint $config $updated }
  $updated
}

export def observation-dir [config: record]: nothing -> path {
  state-root $config | path join "observed"
}

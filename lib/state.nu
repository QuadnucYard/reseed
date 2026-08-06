# Disposable local state: the restore checkpoint lifecycle and the
# observations directory.

use core.nu [expand-home now-string]

# Root of the disposable local state directory (checkpoints, observations).
export def state-root [
  config: record # Loaded configuration; may override the default directory.
]: nothing -> path {
  expand-home ($config.state_dir? | default "~/.local/state/reseed")
}

# Path of the restore checkpoint file. Checkpoints are scoped per profile
# combination and per OS so concurrent restores never share state.
export def checkpoint-path [
  config: record # Loaded configuration; determines the profile scope.
]: nothing -> path {
  let profiles = ($config.active_profiles? | default [default] | str join "-")
  let safe = ($profiles | str replace --all --regex '[^A-Za-z0-9_-]' '_')
  state-root $config | path join "checkpoints" $"restore-($nu.os-info.name)-($safe).nuon"
}

# Load the checkpoint for this restore, or create a fresh one.
#
# With --resume the stored checkpoint must belong to the same source root and
# match the current desired-state fingerprint; either mismatch means the plan
# changed since the restore was interrupted, so resuming is unsafe.
export def load-checkpoint [
  root: path # Private state root the restore operates on.
  config: record # Loaded configuration.
  fingerprint: string # Desired-state fingerprint of the current plan.
  --resume # Accept an existing matching checkpoint.
]: nothing -> record {
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

# Persist a checkpoint under the disposable state directory.
export def save-checkpoint [
  config: record # Loaded configuration; determines the checkpoint path.
  checkpoint: record # Checkpoint to persist.
] {
  let path = (checkpoint-path $config)
  mkdir ($path | path dirname)
  $checkpoint | upsert updated_at (now-string) | to nuon --indent 2 | save --force $path
}

# True when the given stage already completed in this checkpoint.
export def stage-done [
  checkpoint: record # Current checkpoint.
  stage: string # Stage name.
]: nothing -> bool {
  $stage in ($checkpoint.completed? | default [])
}

# Mark a stage as completed. Dry runs return the updated checkpoint without
# persisting it, so a dry run never affects resume state.
export def complete-stage [
  config: record # Loaded configuration; determines the checkpoint path.
  checkpoint: record # Current checkpoint.
  stage: string # Stage name to record.
  --dry-run # Do not persist the update.
]: nothing -> record {
  let updated = ($checkpoint
    | upsert completed (($checkpoint.completed? | default []) | append $stage | uniq)
    | upsert failed null)
  if not $dry_run { save-checkpoint $config $updated }
  $updated
}

# Record the stage that failed and the error message in the checkpoint.
export def fail-stage [
  config: record # Loaded configuration; determines the checkpoint path.
  checkpoint: record # Current checkpoint.
  stage: string # Stage name that failed.
  message: string # Failure detail to record.
  --dry-run # Do not persist the update.
]: nothing -> record {
  let updated = ($checkpoint | upsert failed {stage: $stage message: $message at: (now-string)})
  if not $dry_run { save-checkpoint $config $updated }
  $updated
}

# Directory where backup observations (exports, inventories) are written.
export def observation-dir [
  config: record # Loaded configuration; may override the default directory.
]: nothing -> path {
  state-root $config | path join "observed"
}

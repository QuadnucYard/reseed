# Recovery sequence

`reseed restore` validates all selected profiles, manifests, bootstrap
prerequisites, and mise backend dependencies, prints the work it will perform,
and asks before changing the machine. It then runs:

1. Bootstrap preflight for Git, chezmoi, Nushell, and mise.
2. Curated WinGet imports on Windows or Homebrew Bundle installs on macOS.
3. Backend runtimes required by mise entries, followed by complete `mise install`.
4. Manager manifests through `mise exec`: Cargo-binstall, uv, and the sibling
   pnpm, Yarn, and Bun integrations.
5. Named mise restore tasks, in configuration order.
6. `chezmoi diff` and `chezmoi apply`.
7. Explicit Kopia snapshot restores, when enabled.
8. Cross-tool verification, including every command declared by a manager
   manifest.

Each completed stage is recorded under `~/.local/state/reseed`. Re-run with
`--resume` after interruption; already completed stages are skipped. A normal
restore starts a fresh checkpoint. Dry runs never write checkpoints.
Checkpoint fingerprints include profiles, package manifests, mise configs, and
chezmoi target files, so changed desired state cannot reuse a stale checkpoint.

The sequence is deliberately fixed and small. Native manifests contain only
curated platform-specific software; bootstrap-owned package IDs are excluded
from native refresh, update, and reconcile output. Mise dependencies are
installed in backend order: Node before `npm:*`, Rust before `cargo:*`, and
Python before `pipx:*`. Cargo-binstall is then invoked through the selected
mise configuration, and all manager inventories and verification commands use
`mise exec` with that same configuration.

`reseed reconcile` exports the current package state to the untracked state
directory and reports differences from the tracked desired manifests. It does
not silently add packages or uninstall unlisted software. Bootstrap-owned
native packages are ignored, and manager reconciliation compares unpinned
packages by presence while checking versions only for pinned specs.

When `mise.update` and Cargo-binstall updates are enabled, `reseed update`
passes `--force` to Cargo-binstall so configured crates are refreshed after
mise-managed tools are upgraded.

The source bundle contains one top-level `reseed` directory with the complete
committed Git source, configured payloads, checksums, and available bootstrap
executables for the current platform. Ignored and untracked files are excluded
by construction; explicitly approved external payloads come only from
`bundle.paths`. Bundle creation therefore requires a Git repository, at least
one commit, and no uncommitted tracked changes. A bundle made on Windows
contains Windows tools; create a separate bundle on macOS for Apple Silicon or
Intel recovery.

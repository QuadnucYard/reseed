# Recovery sequence

`reseed restore` validates all selected profiles and manifests, prints the
work it will perform, and asks before changing the machine. It then runs:

1. WinGet imports on Windows or Homebrew Bundle installs on macOS.
2. `mise install` for each selected mise configuration.
3. Configured Cargo crates through `cargo-binstall`, after the bootstrap is installed.
4. Named mise restore tasks, in configuration order.
5. `chezmoi diff` and `chezmoi apply`.
6. Explicit Kopia snapshot restores, when enabled.
7. Cross-tool verification.

Each completed stage is recorded under `~/.local/state/reseed`. Re-run with
`--resume` after interruption; already completed stages are skipped. A normal
restore starts a fresh checkpoint. Dry runs never write checkpoints.
Checkpoint fingerprints include profiles, package manifests, mise configs, and
chezmoi target files, so changed desired state cannot reuse a stale checkpoint.

The sequence is deliberately fixed and small. Native package managers resolve
their own internal dependency graphs, while mise resolves runtime and tool
dependencies. Cargo-binstall is a native portable-tool substage because it
must be bootstrapped before the configured Cargo crates can be installed. A
profile can add ordered mise tasks for exceptional setup that must occur after
runtimes are installed.

`reseed reconcile` exports the current package state to the untracked state
directory and reports differences from the tracked desired manifests. It does
not silently add packages or uninstall unlisted software.

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

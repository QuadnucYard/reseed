# Recovery sequence

`reseed restore` prepares (or imports) the private state, validates all
selected profiles, manifests, bootstrap prerequisites, and mise backend
dependencies, prints the work it will perform, and asks before changing the
machine. With `--state-source <path>` a downloaded private-state source (a Git
checkout, offline bundle, or raw snapshot) is validated, staged, and imported
atomically into the state root first; dry runs validate the source and preview
the plan without writing. The supplied source is immutable and is never
initialized, seeded, updated, or assigned a remote. It then runs:

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

## Repository synchronization

`reseed sync` keeps the private state repository in step with its remote while
preserving local history. One state machine classifies the repository as
missing/unborn, empty remote, clean-synchronized, behind, ahead, dirty,
diverged, detached, shallow, inaccessible, mismatched remote, missing
configured branch, or merge-in-progress, and both `status` and the bootstraps
reuse it. By default sync attaches a remote, fetches, fast-forwards, or merges;
it never commits dirty state or pushes implicitly. `--commit` prints the change
summary, scans for secrets, confirms, and commits; `--push` publishes existing
or newly created commits, retrying once when a push loses a remote race. On
divergence the configured remote branch is merged while both histories are
preserved; conflicts persist their intent outside the repository so
`sync --continue` (after resolving) and `sync --abort` complete or discard the
merge. An empty remote accepts the first push, but a nonempty remote that lacks
the configured branch is refused rather than guessed.

`reseed status` prints machine-readable facts (including the repository phase)
and prioritized, copy-pasteable next commands. The ordering is fixed:
resolve/abort conflicts, import or repair state, install prerequisites, restore
the current fingerprint, configure repository access, then attach/commit/merge/
push state. The same recommendations are reused after `sync` succeeds and
before actionable failures. `status --offline` skips the bounded remote probe
and uses only local and cached facts.

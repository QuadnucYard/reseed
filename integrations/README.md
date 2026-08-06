# integrations

Each module manages one external tool or package manager. Workflows never
call these tools directly; `lib/workflow.nu` composes them, and every
integration exposes the same lifecycle contract.

## Contract

| Operation | Signature | Meaning |
| --- | --- | --- |
| `status` | `(root, config) -> record` | Availability, applicability, and desired-file health for `reseed status` |
| `restore` | `(root, config, --dry-run)` | Bring the machine to the desired state |
| `update` | `(root, config, --dry-run)` | Upgrade managed software without re-importing |
| `reconcile` | `(root, config, --dry-run) -> record or list` | Compare desired with installed, report-only |
| `verify` | `(root, config) -> list<record>` | Checks with `{check, ok, detail}` fields |
| `backup` | `(root, config, --dry-run)` | Capture current state into the source or observations |

`--dry-run` must never change the machine or persist state. Reconcile never
modifies desired state; it only writes observations under the disposable state
directory. All commands that touch a manager run through `mise exec` using the
selected mise config, so a clean shell does not need mise shims on `PATH`.

## Bootstrap contract

`bootstrap.nu` defines the four engine-owned tools — git, chezmoi, Nushell,
and mise — and the WinGet identifiers and Brewfile entries that represent
them. `bootstrap-verify` gates every restore (`--skip-software` drops mise for
offline recovery), and native manifests must not list these packages.

## Native package managers

| Module | Platform | Desired state | Lifecycle |
| --- | --- | --- | --- |
| `winget.nu` | Windows | Curated `winget export` JSON files | `winget import`, per-ID `upgrade`, export + reconcile |
| `homebrew.nu` | macOS | Curated Brewfiles | `brew bundle install`, per-kind `upgrade`, dump + reconcile |

Both filter the bootstrap contract from refresh, update, and reconcile output
(`native-winget-manifest-ids`, `native-brewfile-items`) and degrade export
failures to warnings.

## Portable tool managers

The package-manager modules live under `managers/`, mirroring the
`packages/<manager>/` layout of the private state; the Node family
(pnpm/Yarn/Bun) shares `managers/node/`.

| Module | Purpose |
| --- | --- |
| `mise.nu` | Portable-tools stage: installs mise configs in backend order (Node before `npm:*`, Rust before `cargo:*`, Python before `pipx:*`), runs the Cargo-binstall/uv/Node manager lifecycles, then the configured restore tasks |
| `managers/cargo_binstall.nu` | Cargo binary crates from `packages/cargo/binstall.nuon`; `update` passes `--force` |
| `managers/uv.nu` | uv tools from `packages/uv/tools.nuon`; specs pin with `==` |
| `managers/node/node_manager.nu` | The shared pnpm/Yarn/Bun engine: spec parsing (`name` or `name@version`), install/update arguments, inventory parsing (JSON, Yarn JSONL trees, Bun text fallback), and the Yarn-1-only guard (`yarn global` commands were removed in Yarn 2) |
| `managers/node/pnpm.nu`, `bun.nu`, `yarn.nu` | Thin wrappers over `node_manager.nu` per manager |
| `tooling.nu` | Observation capture for managers Reseed does not own (npm, and raw Cargo/pnpm/Bun/uv/Yarn state) with migration hints; every run goes through `mise exec` when mise is enabled |

Package records are `{spec, name, version, commands}`. Entries may be strings
or `{spec, commands}` records; the commands are verified in the shared managed
binary directory by `lib/managed_tools.nu`. Shared plumbing — manifest
reading, entry merging, missing-package detection, and the reconcile/verify
builders — lives in `lib/manager_core.nu`.

## Configuration and snapshots

| Module | Purpose |
| --- | --- |
| `chezmoi.nu` | Dotfile restore (`diff` then `apply`), backup (`re-add`), and verification against the private source |
| `kopia.nu` | Explicit snapshot/restore entries with `~` expansion; repository credentials stay external |

## Adding an integration

1. Create one module with the contract functions above. Package managers go
   under `managers/` (add a subdirectory like `node/` when a family grows
   multiple modules); everything else sits at the top level.
2. Reuse `lib/manager_core.nu` and `run-mise-managed` for package managers;
   follow the existing observation and reconcile record shapes.
3. Wire it into `lib/workflow.nu` where its dependencies are available, and
   extend `workflow-verification-tools` when it needs a verification stage.
4. Keep dry runs side-effect free and never write outside the disposable state
   directory. Run `nu tests/run.nu` before finishing.

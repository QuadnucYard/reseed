# Reseed

Reseed restores Windows and macOS workstations by coordinating mature native
tools. This repository is the reusable engine. Personal configuration belongs
in a separate private state repository.

| Location | Purpose | Synced where |
| --- | --- | --- |
| Reseed engine | CLI, bootstraps, integrations, tests, state template | General engine remote |
| `~/.local/share/reseed` | Dotfiles, package manifests, profiles, mise tools | Your private Git remote |
| `~/.local/state/reseed` | Observations, restore checkpoints, sync/import records | Nowhere; disposable local state |

On this Windows machine, the private state path resolves to
`C:\Users\dell\.local\share\reseed`. Set `RESEED_STATE_ROOT` or pass
`--state-root` to use another path.

## Private state

`reseed init` copies the generic scaffold from `templates/state/` into the
private location and runs `git init -b main`. It refuses a nonempty directory
without the `.reseed-state` sentinel. Re-running it is safe: it also copies any
missing engine-owned template file (such as `scripts/configure-shells.nu`) into
an existing state repository, and `reseed restore` and `reseed update` do the
same before validating desired state, so a repository that lost its shell
generator repairs itself.

```powershell
# Initialize local private state. This is safe to run again.
nu reseed.nu init

# Attach a private remote you created on your Git host. On an existing state
# root this also adopts the remote state (pulling recovery.nuon, profiles, and
# manifests into the local scaffold) when it is safe to do so.
nu reseed.nu init --remote-url <private-state-git-url>

# Capture, commit, and push the private state.
nu reseed.nu backup --commit --push

# Review the repository state and get the next command.
nu reseed.nu status

# Synchronize: attach a remote, fetch, fast-forward, or merge while keeping
# local history. --commit reviews and commits dirty state; --push publishes.
nu reseed.nu sync
nu reseed.nu sync --commit --push
nu reseed.nu sync --continue   # finish an interrupted merge
nu reseed.nu sync --abort      # discard an interrupted merge
```

The engine never chooses a hosting provider or remote URL. It also refuses to
replace an existing `origin` with a different URL. A state root that has local
commits or uncommitted changes is left untouched by `init --remote-url`; use
`reseed adopt --remote-url <url> --replace` to explicitly discard local work in
favor of the remote state, or `reseed sync` to merge and publish instead.

The remote URL resolution order is: the existing `origin` URL, then
`--remote-url`, then the optional `git.url` in `config/recovery.nuon`. URLs
stored in state are non-secret: a `git.url` embedding HTTP credentials or
tokens is rejected.

The private repository contains all desired workstation state:

```text
~/.local/share/reseed/
├── .chezmoiroot          points chezmoi at home/
├── config/               recovery policy and profile overlays
├── home/                 private chezmoi source files
├── packages/             native and manager manifests
├── scripts/              private idempotent restore tasks
└── mise.toml             shared runtimes and portable tools
```

## Tool ownership

Reseed has three software ownership layers:

- The engine bootstrap contract owns Git, chezmoi, Nushell, and mise. The
  platform bootstrap scripts install these through WinGet or Homebrew, and
  private native manifests must not list them.
- Shared mise `[tools]` owns runtimes and portable tools that are common to
  platforms. The shared configuration uses Node, explicit Aqua pnpm and uv,
  Cargo-binstall, Starship, and the configured npm tool.
- Manager manifests own packages whose installation semantics belong to a
  package manager: Cargo binaries in `packages/cargo/binstall.nuon`, uv tools
  in `packages/uv/tools.nuon`, and Node package-manager globals in the sibling
  manifests under `packages/node/` for pnpm, Yarn, and Bun.

WinGet and Homebrew manifests contain only curated platform-specific software.
Kopia can optionally snapshot narrow opaque application state. The restore
order is bootstrap preflight, native packages, mise tools, manager manifests,
chezmoi, shell adapters, snapshots, and verification.

The shared manager binary directory is `~/.local/share/reseed/bin`. It is
ignored by the private repository. After chezmoi applies the home state, the
configured `shell_task` generates Nushell and Fish automatic adapters plus
separate Bash, Zsh, and PowerShell adapters. Unmanaged profiles receive an
idempotent loader block; chezmoi-managed profiles must source the generated
adapter in their desired source. The adapters set `MISE_GLOBAL_CONFIG_FILE` to
the absolute configured `shell_config`, activate mise, and preserve the
detected Homebrew prefix, so alternate state roots work in every directory.

## Daily commands

These use the default private state path:

```sh
nu reseed.nu
nu reseed.nu plan --profiles personal
nu reseed.nu status --profiles personal
nu reseed.nu status --offline
nu reseed.nu sync --profiles personal
nu reseed.nu backup --profiles personal
nu reseed.nu reconcile --profiles personal
nu reseed.nu restore --profiles personal
nu reseed.nu update --profiles personal
nu reseed.nu verify --profiles personal
nu reseed.nu bundle --output reseed-source.tar.gz
```

Running `reseed` with no subcommand prints a compact summary of the machine:
whether the fundamental software (Git, chezmoi, Nushell, mise) is in place,
whether the local state is initialized, configuration health, whether the
machine is restored to the current desired state, and the prioritized,
copy-pasteable next commands. It uses only local and cached facts, so it
returns immediately even when the remote is unreachable; use `reseed status`
for the full online view with a bounded remote probe (or `status --offline` to
skip it).

Use `--dry-run` to print commands, `--yes` for unattended restore/update,
`--resume` after an interrupted restore, and `--skip-software` for an offline
configuration-only restore. Every command accepts `--state-root`.

`status` probes the remote read-only (bounded) and prints the repository phase
plus prioritized, copy-pasteable next commands; `status --offline` uses only
local and cached facts. `sync` attaches a remote, fetches, fast-forwards, or
merges while preserving both histories, and its recommendations are reused
after every command that changes the repository.

`backup` captures chezmoi changes and writes package-manager observations under
the disposable state directory. Observations are not automatically promoted.
Only entries deliberately kept in the private WinGet manifest, Brewfile,
`mise.toml`, or restore tasks are synchronized. Removing an entry stops future
restore/update management but does not uninstall it locally.

Avoid `backup --refresh-manifests` during routine backups. That option
deliberately replaces a curated native manifest with the full machine export.

## Add dotfiles

Run chezmoi against the private source, not this engine repository:

```sh
chezmoi --source ~/.local/share/reseed add ~/.gitconfig
chezmoi --source ~/.local/share/reseed add ~/.config/starship.toml
chezmoi --source ~/.local/share/reseed diff
```

Nushell's entry files are under `%APPDATA%\nushell` on Windows and
`~/Library/Application Support/nushell` on macOS. Review environment files for
tokens before adding them. See [customizing](docs/customizing.md) and the
[backup inventory](docs/backup-inventory.md).

## Guided setup

`reseed setup` walks through user identity, SSH keys, GitHub uploads, and
commit signing. The full wizard covers everything; per-purpose subcommands
run one area at a time:

```powershell
nu reseed.nu setup
nu reseed.nu setup ssh
nu reseed.nu setup gh
nu reseed.nu setup gpg
```

Every run prints a dependency-ordered plan, skips steps that are already
satisfied, and ends with a pass/fail summary. jj and GPG are optional features
that default to on (`--no-jj`, `--no-gpg`). See the [guided setup](docs/setup.md)
for purposes, host configuration, and security notes.

## New machine

First obtain this general engine repository. Then let its bootstrap install the
small native dependency chain and clone the private state repository.

Windows PowerShell:

```powershell
.\bootstrap.ps1 -StateRepository <private-state-git-url> -Profiles personal
```

macOS:

```sh
./bootstrap.sh --state-repository <private-state-git-url> --profiles personal
```

The older `-Repository`/`--repository` spelling remains an alias for the private
state repository. Credentials for cloning must already be available through
SSH, a credential manager, or an interactive Git helper. When the state root is
already initialized, the bootstrap fast-forwards it from the provided
repository first, so a stale local copy (for example one missing a recently
added `config/recovery.nuon`) repairs itself before restore runs.

### Recover from a downloaded state source

When the private repository cannot be cloned directly but a downloaded snapshot
is available (a Git checkout, an offline bundle, or a raw snapshot directory),
pass it as an immutable state source instead of a repository:

```powershell
.\bootstrap.ps1 -StateSource .\downloaded-state -Profiles personal
```

```sh
./bootstrap.sh --state-source ./downloaded-state --profiles personal
```

`-StateSource`/`--state-source` is mutually exclusive with `StateRepository`.
The source is validated (it must carry the `.reseed-state` sentinel and a valid
selected configuration), staged, and imported atomically into the state root
before restore runs. It is never initialized, seeded, updated, or assigned a
remote; a rerun with the same source is a no-op and a different source against
an already-initialized root is refused. The same flow is available directly:

```sh
nu reseed.nu restore --state-source ./downloaded-state.tar.gz
```

Git-checkout sources are cloned locally without hardlinks and their modified,
deleted, and non-ignored untracked files are overlaid on top; bundle and raw
snapshots copy non-ignored state files and retain any available revision
metadata. A bundle's recorded `state_revision` is preserved as the merge base
when the remote still contains that commit: sync rebases the recovered snapshot
(and any commits made after the import) onto it, so the snapshot merges with
the remote history instead of being treated as unrelated. When the remote does
not contain `state_revision` (for example an artifact newer than the remote),
or the snapshot has no recorded provenance, sync attaches the fetched remote as
the baseline and exposes the complete recovered-snapshot difference for review
before merging both histories.

### No repository yet? Bootstrap first, link later

When the private repository cannot be used yet (no SSH key, no `gh` auth, no
network to the host), run the bootstrap without `--state-repository`. It seeds
the generic template into the state root, restores the machine from it, and
leaves the state root uncommitted so it can be linked later. Once network
access is configured, connect it to the private repository:

```sh
nu reseed.nu adopt --remote-url <private-state-git-url>
```

`reseed adopt` pulls the real private state (including `config/recovery.nuon`)
into the existing root without re-running the whole bootstrap. It adopts a
template seed directly and refuses to overwrite local commits or uncommitted
changes unless you pass `--replace`. The bootstraps' `--state-repository` flag
is the equivalent one-step path when the repository is available at bootstrap
time. For the richer synchronization behavior (fast-forward, merge on
divergence, reviewed commits, and push) the guidance recommends
`reseed sync`. A seed that lost a file (for example an interrupted seed missing
`config/recovery.nuon`) repairs itself: re-running `reseed init` re-seeds any
missing template files into the uncommitted seed, so `reseed setup` and
`reseed restore` can run even before the private repository is reachable.
Committed private state is never re-seeded.

When the network cannot reach GitHub (common in China), Homebrew bootstrap
accepts `--homebrew-mirror ustc|tuna` to route the installer and package
downloads through a China mirror, or `--brew-install-url URL` to point at a
specific installer script. The installer download and its execution are
bounded by timeouts, and a non-interactive install that needs an admin
password retries interactively. Homebrew package downloads during later
`reseed restore` runs use the mirrors configured in the private state's
`software.homebrew.env` (see [customizing](docs/customizing.md)).

The configured mirror is also persisted for interactive shells: every
`reseed restore` and `reseed update` regenerates shell snippets that export
the same environment. Nushell and Fish load them automatically; POSIX and
PowerShell users source `~/.local/share/reseed/shell/reseed-homebrew-env.sh`
(or `.ps1`) from their profile, exactly like the managed-tools adapters.

On macOS the restore also installs Finder context-menu items as Automator
Quick Actions: "Open Terminal Here" opens the frontmost Finder window's
folder in a terminal, and two "Open in VS Code" entries act on exclusive
contexts — the frontmost Finder window's folder and the right-clicked
selection. They can be managed directly with `reseed finder status|restore|verify`
and disabled with `software.finder_services.enabled: false` in
`recovery.nuon`. See [docs/finder.md](docs/finder.md).

When the bootstrap contract tools (Git, chezmoi, Nushell, mise) are already
installed, the bootstrap checks them for available upgrades: on an interactive
terminal it prompts before upgrading anything, while non-interactive runs
(e.g. CI) only report. Pass `--update-tools`/`-UpdateTools` to upgrade without
prompting, or `--no-update-tools`/`-NoUpdateTools` to skip the check entirely.
On the engine side, `reseed status` reports each tool's installed and
available versions, and `reseed verify` warns when a bootstrap tool is
outdated (advisory; verification still passes).

## Offline recovery

Bundles contain separate committed `engine/` and `state/` snapshots plus
platform bootstrap executables and checksums. After extraction:

```powershell
.\reseed\engine\bootstrap.ps1 -Offline -StateRoot ..\state
```

```sh
./reseed/engine/bootstrap.sh --offline --state-root ../state
```

Ignored and untracked files are excluded from both Git snapshots. Optional
payloads come only from the private state's `bundle.paths`. Offline recovery
still requires the bootstrap contract's Git, chezmoi, and Nushell tools.
Normal software recovery additionally requires mise; offline recovery uses
`--skip-software`.

## Secrets

Do not commit passwords, tokens, recovery codes, private SSH/GPG keys, browser
profiles, or whole AppData/Library trees. Keep secret values in a password
manager, Windows Credential Manager, macOS Keychain, or chezmoi's encrypted
and password-manager integrations. Kopia repository credentials must remain
external to both repositories.

See [recovery](docs/recovery.md) for stage ordering and resume behavior.

## Engine internals

- [lib/README.md](lib/README.md) — the core library: configuration loading and
  validation, Git operations, checkpoints, manager plumbing, and the workflow
  orchestration layer.
- [integrations/README.md](integrations/README.md) — the per-tool integration
  contract (status/restore/update/reconcile/verify/backup) and how to add a new
  integration.
- [customizing](docs/customizing.md) and [backup inventory](docs/backup-inventory.md)
  describe the private state format and daily capture behavior.
- [guided setup](docs/setup.md) documents the setup wizard, its purposes, and
  the `setup` configuration section.

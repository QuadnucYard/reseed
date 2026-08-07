# Backup inventory

This report separates declarative configuration from credentials, caches, and
opaque application state. It was checked against the Windows machine on
2026-08-05. Existence checks did not open credential-bearing files.

## Highest-priority additions

| Configuration | Current Windows path | Status | Recommended owner |
| --- | --- | --- | --- |
| Nushell config | `%APPDATA%\nushell\config.nu` | Present, 518 bytes | chezmoi after token review |
| Nushell environment | `%APPDATA%\nushell\env.nu` | Present, 4559 bytes | chezmoi template after token review |
| Git config | `~/.gitconfig` | Present, 212 bytes | chezmoi |
| Cargo config | `~/.cargo/config.toml` | Present, 465 bytes | chezmoi after registry credential review |
| PowerShell profile | `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1` | Present, 296 bytes | chezmoi |
| Windows Terminal | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` | Present, 4639 bytes | chezmoi template |
| VS Code settings | `%APPDATA%\Code\User\settings.json` | Present, 28617 bytes | chezmoi or Settings Sync, not both |
| VS Code keybindings | `%APPDATA%\Code\User\keybindings.json` | Present, 1387 bytes | same owner as VS Code settings |
| Jujutsu config | `%APPDATA%\jj\config.toml` | Present, 441 bytes | chezmoi |
| Starship config | `~/.config/starship.toml` | Added to Reseed | chezmoi |

Before adding these, scan for embedded access tokens, private registry
credentials, machine-only paths, and employer-specific values. Put optional or
role-specific settings in profile overlays or chezmoi templates.

## macOS checklist

On a Mac, review and add the corresponding user-authored files:

- `~/Library/Application Support/nushell/config.nu` and `env.nu`
- `~/.config/fish/config.fish`, `conf.d/`, and hand-authored functions
- terminal configuration for Terminal, iTerm2, WezTerm, Ghostty, or Alacritty
- Git, Jujutsu, Cargo, editor, and package-manager configuration
- narrow, idempotent `defaults` commands for preferences that cannot be files

Fish universal variables can contain transient or private state. Curate
`fish_variables` rather than copying it by default. Registering Fish in
`/etc/shells` and changing the login shell should remain an explicit opt-in
step because it changes system state.

## Credentials kept outside Git

Do not commit SSH or GPG private keys, `.git-credentials`, Cargo credentials,
npm tokens, `.pypirc`, GitHub or GitLab authentication, cloud credentials,
Kubernetes client credentials, Docker authentication, `.env` files, browser
sessions, or Kopia repository passwords.

Track structure such as `~/.ssh/config`, public keys, Git identity, registry
URLs, signing key IDs, and certificate paths only after review. Obtain secret
values from a password manager, Windows Credential Manager, macOS Keychain, or
chezmoi's encrypted/password-manager integrations.

## Excluded generated state

Do not back up whole AppData or Library trees, shell history, Nushell
`plugin.msgpackz`, generated completion files, browser profiles, VS Code
`globalStorage` or `workspaceStorage`, Cargo registries/toolchains/targets,
pnpm stores, Bun global `node_modules`, uv caches or downloaded interpreters,
Homebrew Cellar/cache, WinGet caches, drivers, registry hives, DPAPI blobs, or
project build outputs.

Do not back up `~/.local/share/reseed/bin/` or its generated shell adapters;
these are recreated from the manager install-root variables and the configured
`shell_task`. Generated Bash, Zsh, PowerShell, Fish, and Nushell files remain
machine state; only authored loader lines in chezmoi-managed profiles belong
in the private repository. Generate completions and Nushell vendor autoload
files from managed tools.
Use native browser/editor sync for data already owned there. Use Kopia only for
narrow, valuable application databases that cannot be represented
declaratively, and define how the restore snapshot is selected before enabling
it; a fixed snapshot ID otherwise becomes stale after later backups.

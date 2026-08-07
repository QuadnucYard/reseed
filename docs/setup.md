# Guided setup

`reseed setup` walks through user identity, SSH keys, GitHub uploads, and
commit signing. Every run prints a plan, asks before each step that is not
already satisfied, and ends with a pass/fail summary. Purposes share steps:
for example, `ssh-remote` reuses the key generation step of `ssh-local`.

## Commands

```powershell
# Everything: identity, SSH, GitHub, GPG signing.
nu reseed.nu setup

# One purpose at a time.
nu reseed.nu setup identity
nu reseed.nu setup ssh-local
nu reseed.nu setup ssh-remote
nu reseed.nu setup ssh
nu reseed.nu setup gh
nu reseed.nu setup gpg
```

Every command accepts `--yes` (apply defaults without prompting), `--dry-run`
(preview without changing the machine), `--no-jj`, and `--no-gpg`; the shared
`--profiles` and `--state-root` flags work as in the other commands.

| Purpose | Steps |
| --- | --- |
| `identity` | Git and jj `user.name`/`user.email` |
| `ssh-local` | SSH agent and `~/.ssh/id_ed25519` generation |
| `ssh-remote` | Public key on every host in `setup.ssh.hosts`; admin entries also update the host's admin allow list |
| `ssh` | Local keys, remote hosts, and passwordless-login tests |
| `gh` | GitHub CLI authentication and SSH key upload |
| `gpg` | GnuPG key generation, GitHub upload, Git and jj signing configuration, and a signed-commit check |

## Wizard behavior

The wizard resolves each purpose into a dependency-ordered step plan, prints
it, and runs the steps one by one:

- Steps that are already satisfied (a key exists, the identity is set, the
  key is already on GitHub or on the hosts) are skipped automatically.
- Steps that would change the machine are confirmed first; declining a step
  records it as skipped and the wizard continues.
- The final table lists every step with its status; the command fails when
  any step failed.

Steps share a dependency graph, so a purpose never repeats work: `ssh-key`
runs once even when both `ssh-github` and `ssh-hosts` need it, and every
purpose that touches identity pulls in the identity step automatically.

## Optional features

jj and GPG are optional features that default to on:

- **jj**: detected via `command-exists jj`. When missing, the wizard asks
  whether to install it (default yes) through mise, WinGet, or Homebrew.
  Declining skips the jj parts of identity and signing. When configuring jj
  signing, the wizard asks which `signing.behavior` to use when rewriting
  commits — `drop`, `keep`, `own` (default), or `force` — so `--yes`
  automation signs the commits you author.
- **gpg**: detected via `command-exists gpg`. When missing, the wizard asks
  whether to enable GPG signing setup (default yes) and installs GnuPG
  (WinGet or Homebrew); without administrator rights on Windows it prints
  manual installation instructions.

`--no-jj` and `--no-gpg` force the features off without asking, for
automation.

## GitHub uploads

Uploads go through the `gh` CLI:

- SSH keys use the `admin:public_key` scope.
- GPG keys use the `write:gpg_key` scope.

The wizard detects a missing or invalid login (including a revoked token) and
offers `gh auth login`; when a scope is missing it offers `gh auth refresh
-h github.com -s <scope>` before retrying the upload.

## Hosts

Configure hosts in the private state's `config/recovery.nuon`:

```nuon
setup: {
  ssh: {
    # SSH key comment; defaults to the Git identity email.
    comment: "alice@example.com"
    hosts: [
      # os selects the admin allow list: windows, macos, or unix.
      {user: "alice" host: "home.example.com" port: 22 admin: false os: "unix"}
      {user: "Administrator" host: "win.example.com" admin: true os: "windows"}
    ]
  }
  gpg: {
    key_type: ed25519
  }
}
```

`setup.ssh.hosts` entries require `user` and `host`; `port` (default 22),
`admin` (default false), and `os` (default unix) are optional. Host entries
are validated by `reseed status` and every workflow. Remove an entry to stop
future setup runs from touching that host; the key already on the host is
never removed.

When `admin` is true, the setup also appends the public key to the host's
admin allow list:

| Host `os` | Admin allow list |
| --- | --- |
| `windows` | `C:\ProgramData\ssh\administrators_authorized_keys` |
| `macos` | `/var/root/.ssh/authorized_keys` |
| `unix` | `/root/.ssh/authorized_keys` |

## Security notes

SSH keys are ed25519 without a passphrase and GPG keys are ed25519 signing
keys without a passphrase, so restores and scripts never stall on a prompt;
protect the private key files the way you would any other secret. GPG keys
inherit the name and email from the Git identity configured by the identity
step.

# lib

The engine's core library. `reseed.nu` is the thin command-line facade; every
workflow it exposes delegates to `workflow.nu`, which composes these modules.
All functions are documented in Nushell's help syntax: `nu -c "use lib/core.nu *; help run-command"`.

Dependency direction runs from low-level utilities up to orchestration:

```text
core → managed_tools → manager_core → mise → config → git → state → workflow
```

`repo.nu` is the private repository state machine (probe, sync, merge
continue/abort, conservative refresh) shared by status, sync, the bootstraps,
and update; `import.nu` validates and atomically imports downloaded state
sources; `advice.nu` is the pure prioritized recommendation layer rendered by
status and reused after sync. `git.nu` keeps the bundle builder and the
configuration-aware commit/pull/init helpers.

`setup.nu` is a separate facade for the guided setup wizard (identity, SSH
keys, GitHub uploads, and GPG signing); the implementation lives in the
`setup/` submodules (plan, shared, common, provider, ssh, gpg), which import
only `core.nu`, and the facade is called directly from `reseed.nu`, outside the
recovery workflows.

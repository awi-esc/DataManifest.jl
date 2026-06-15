# Configuration

The configuration system is shared by every implementation: the variables
(`datasets_dir`, `datacache_dir`, the pools, `project`, `canonical`,
`lock_stale_age`, user-defined `$`-symbols), the five scopes a value can be
set in (environment variable, checkout config, manifest `[_STORAGE]`, user
config, built-in default), host-specific `_HOST` values, and the resolution
rule that decides which value wins. The full reference lives on
the central site:
**[Configuration](https://perrette.github.io/datamanifest/configuration/)**.
The files can be edited directly or with [`datamanifest config
set`](https://perrette.github.io/datamanifest/cli/) — both tools read and
write the same files.

## Julia specifics

**The frozen snapshot.** In Julia the whole ladder — environment included —
is evaluated **once, when a `Database` is materialized**: the database takes a
`Storage.ConfigSnapshot` capturing the three file layers together with the
environment and hostname, so every variable has one well-defined value for
the Database's lifetime, even if files or environment change underneath. To
pick up changes, re-read the manifest or call `freeze_config!(db)`; assigning
`db.storage_config` or `db.datasets_toml` also invalidates the snapshot (it is
frozen again on next use). Command-line invocations, by contrast, read the
configuration afresh on every run.

**`canonical` output.** The `canonical` setting (write manifests in the
byte-identical canonical form, via the Python `datamanifest format` command)
resolves on the ordinary ladder, and is also available per call as
`write(db, path; canonical=true)`. The CLI is looked up next to the manifest
(`<manifest dir>/.venv/bin/datamanifest`, falling through to the main
checkout's `.venv` from a linked git worktree) and then on `PATH`; when it is
absent, the native TOML is written instead, with a warning.

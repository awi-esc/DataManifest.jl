# Changelog

## [Unreleased]

### Breaking

- **New projects default to `datamanifest.toml`**, the canonical manifest name
  shared with the Python tool. When no manifest exists yet, the inferred
  default path (and hence the file created on first write) is now
  `<project root>/datamanifest.toml` instead of `Datasets.toml`. Existing
  projects are unaffected: an existing `Datasets.toml` is still discovered.
  The full discovery order (first existing file wins, identical in both
  tools) is: `datamanifest.toml` > `DataManifest.toml` > `datasets.toml` >
  `Datasets.toml`. The order lives in `Config.MANIFEST_FILENAMES` and is also
  used when locating the nearest manifest's `[_STORAGE]` table.

## [0.31.0] - 2026-06-11 — spec-v5.5: the configuration is frozen at materialization

Tracks datamanifest.toml **`spec-v5.5`** (configuration evaluation timing).

### Changed

- **The configuration is frozen at Database materialization.** `Database` now
  captures a `Storage.ConfigSnapshot` — the three file-backed layers (checkout
  config, manifest `[_STORAGE]`, user config) **together with the environment
  and host** — when it is materialized, and every resolution (the folder
  fields, pools, symbols, `canonical`, `lock_stale_age`) runs against that
  snapshot. The whole ladder, environment rung included, is evaluated against
  load-time state, so each config variable has one well-defined value for the
  Database's lifetime; the per-call config-file re-reads and the worktree
  `git rev-parse` probe also leave the path-resolution hot path. Re-read the
  files and environment deliberately with `freeze_config!(db)` (exported). A
  snapshot is authoritative — every resolution against it uses its captured
  env/host; foreign-context resolution (e.g. a remote machine's
  probed environment) builds its own snapshot. Directly assigning
  `db.storage_config` (or `db.datasets_toml`) invalidates the snapshot, which
  is re-frozen on next use. Mirrors the Python tool, where the `ScopedConfig`
  built at Database init now also carries the frozen env/host.

## [0.30.0] - 2026-06-11 — spec-v5.4: `_*`-tables first, the `canonical` directive

Tracks datamanifest.toml **`spec-v5.4`** (canonical ordering with structural
`_*` tables first, the `canonical` config field, worktree config fallback).

### Changed

- **Native manifest output orders `_*` tables first.** The Julia TOML
  serialization now sorts top-level keys the same way the Python tool does —
  structural `_*` tables (`_META`, `_LANG`, `_LOADERS`, `_STORAGE`) first,
  then datasets, both alphabetical. Previously a plain code-point sort dropped
  `_META` between the upper-cased and lower-cased dataset names, so rewriting
  a Python-written manifest moved it to the middle of the file. Remaining
  native-format differences (inline vs. multi-line arrays, indentation of
  nested tables) are TOML-library formatting with no stdlib knobs; use the
  canonical pipe below for byte-identical output.

- **`canonical` config field pipes every persisted manifest through the Python
  CLI.** A new opt-in directive on the ordinary resolution ladder —
  `DATAMANIFEST_CANONICAL` env → checkout config (`.datamanifest/config.toml`)
  → manifest `[_STORAGE]` → user config, within a layer `_HOST` glob before the
  base value (`Storage.canonical_write`). When truthy (TOML `true`, or
  `1`/`true`/`yes`/`on` case-insensitive), `write` defaults to the
  `canonical=true` behavior from 0.16.0: the manifest is piped through
  `datamanifest format` so Julia and Python emit byte-identical files. The CLI
  is looked up next to the manifest first (`<manifest dir>/.venv/bin/datamanifest`,
  falling through to the main checkout's `.venv` from a linked git worktree),
  then on `PATH`; when absent, the native TOML is written and a warning is
  emitted once per session. An explicit `write(db, path; canonical=true|false)`
  overrides the ladder either way. `canonical` is a reserved `[_STORAGE]` key
  (not a user symbol).

- **Linked `git worktree`s read the main checkout's config file.** The
  checkout-scope config lookup (`.datamanifest/config.toml`) now applies the
  same worktree fallback as the spec-v5.1 state file: a worktree starts without
  the git-ignored `.datamanifest/` directory, so when it has no config file of
  its own and sits inside a linked worktree, `config_layers` reads the
  corresponding file in the main checkout. A config file present in the
  worktree itself always wins. (`Cache._main_checkout_dir` moved to
  `Storage._main_checkout_dir`; the state-file behavior is unchanged.)

## [0.29.2] - 2026-06-11 — spec-v5.3: `lock_stale_age` config field

### Added

- **The lock staleness age is the config field `lock_stale_age`** (seconds,
  default 30), resolved on the ordinary scoped ladder —
  `DATAMANIFEST_LOCK_STALE_AGE` env → `.datamanifest/config.toml` → manifest
  `[_STORAGE]` → user config (`_HOST`-composable like any field; TOML number or
  numeric string). `Storage.lock_stale_age` is the resolver; the produce
  (`@cached`) and fetch paths resolve it with their full project config, and a
  bare `materialize` call falls back to env + config files.

### Fixed

- **State-file staging name is task-unique.** `write_index` staged under
  `state.toml.<pid>.tmp`, so two tasks of one process registering concurrently
  (now a normal occurrence under wait-on-contention) could rename each other's
  staging file away mid-write; the name now carries the task identity.

## [0.29.1] - 2026-06-11 — instant reclaim of long-stale locks

### Fixed

- **A lock already stale on arrival is reclaimed immediately under `:wait`.**
  The stdlib `mkpidlock` blocking path runs its first staleness check only after
  one full `stale_age` of waiting, so a contender arriving hours or days after a
  holder crashed would still have waited 30s. `materialize` now makes a
  non-blocking attempt first (which checks and reclaims stale locks up front)
  and only falls back to the blocking wait on a fresh lock — i.e. a live holder,
  or a crash within the last `stale_age` seconds (indistinguishable until the
  heartbeat is missed).

## [0.29.0] - 2026-06-11 — spec-v5.2: wait on lock contention (compute-once)

Tracks datamanifest.toml **`spec-v5.2`** (lock contention: wait, heartbeat,
bounded staleness). Concurrent workers — e.g. HPC jobs hitting the same
`@cached` variation — now compute an artifact **once** and load it everywhere
else, instead of the second worker crashing on the lock.

### Changed

- **Lock contention now waits (was: raise).** `materialize` takes the
  `<target>.lock` pidfile via the stdlib `FileWatching.Pidfile`: the holder
  refreshes the lock's mtime every `stale_age/2` (a heartbeat, so a live
  holder's lock never goes stale however long the write takes), and a
  contender **blocks** until the lock is released or goes stale. The previous
  raise-on-contention behavior is available as `on_locked=:fail`, and
  `on_locked=:proceed` (the Python tool's old behavior) writes without
  exclusivity through process-private staging. A lock is reclaimed as stale
  once its age exceeds `stale_age` (default 30s, `$DATAMANIFEST_LOCK_STALE_AGE`
  overrides) AND its PID is dead on this host or the age exceeds 5×`stale_age`
  (missed heartbeats: a holder crashed on another node, or frozen). A wrong
  reclaim is safe by construction (staging + atomic rename + completion
  marker): worst case duplicate work, never a partial entry.
- **Recheck after acquiring (`skip_if`).** `materialize` accepts a
  `skip_if(target)` predicate evaluated once the lock is acquired; the
  `@cached` produce path passes its hit check, so a waiter loads what its peer
  just published instead of recomputing, and the fetch path passes
  `is_complete` (unless `overwrite`), so a waiter adopts a peer's download.
- **Lock file format.** The pidfile now records `<pid> <hostname>` (the stdlib
  `Pidfile` format, shared with the Python tool); legacy bare-PID locks are
  still read (empty hostname = local).

## [0.28.1] - 2026-06-11 — git worktrees share the main checkout's state file

### Fixed

- **Linked `git worktree`s find the project's state file.** A worktree starts
  without the git-ignored `.datamanifest/` directory, so state lookups used to come
  up empty there. When the project directory has no state file of its own and sits
  inside a linked worktree, `locate_state` now falls through to the corresponding
  directory in the **main checkout** — both for reading and as the write target, so
  all worktrees share one inventory. Detection asks the `git` executable
  (`git rev-parse`); when `git` is unavailable, the repository is bare, or the
  directory is not in a worktree, behavior is unchanged. A state file present in
  the worktree itself always wins.

## [0.28.0] - 2026-06-10 — spec-v5: global defaults, scoped config, `.datamanifest/`

Tracks datamanifest.toml **`spec-v5`** (storage v5, phase 1 — the spec-normative
surface). The two folder fields default to machine-global locations, a `$project`
symbol namespaces the produced cache, two git-ignored config files carry per-machine
directives on a git-style resolution ladder, and the state file moves into a
per-checkout `.datamanifest/` directory.

### Breaking

- **New built-in folder defaults — data no longer lands repo-locally by default.**
  `datasets_dir = "$user_data_dir/datamanifest/shared/datasets"` (one keyed store,
  shared and de-duplicated across projects) and
  `datacache_dir = "$user_cache_dir/datamanifest/projects/$project/cached"`
  (per-project). Existing data keeps resolving: repo-local datasets are found via the
  new `$repo/datasets` default read pool (adopted, never re-downloaded), and produced
  artifacts at their recorded locations via the state file's read-first resolution.
  Set `datasets_dir = "datasets"` / `datacache_dir = "cached"` (manifest or config
  file) to keep the previous repo-local layout; manifests migrated from spec-v3 pin
  that explicitly and behave unchanged.
- **State file relocated** to `.datamanifest/state.toml` (canonical). The legacy
  `.datamanifest-state.toml` and `cached.toml` paths are still read; the first
  `write_index` relocates the file (legacy removed only after the canonical write
  lands) and drops a `.datamanifest/.gitignore` containing `*`, so the whole
  directory is git-ignored with no setup. The `Cache.STATE_FILE_NAME` constant now
  holds the relative path `.datamanifest/state.toml` — code joining it to a project
  root keeps working; code assuming a bare sibling filename must adapt.
- **`project` is now a reserved `[_STORAGE]` key** (the `$project` symbol's override),
  no longer available as a user-defined symbol name.

### Added

- **`$project` predefined symbol** — the project name; defaults to the basename of
  the project root, overridable as a bare `project` field anywhere on the ladder
  (a committed `[_STORAGE].project` names the project for every collaborator).
- **Scoped config files**: `.datamanifest/config.toml` (per-checkout, git-ignored)
  and `$XDG_CONFIG_HOME/datamanifest/config.toml` (user-global), both
  `[_STORAGE]`-shaped including `_HOST` sections. Resolution ladder (first match
  wins): `DATAMANIFEST_<NAME>` env → checkout config → manifest `[_STORAGE._HOST]`
  → manifest `[_STORAGE]` → user config → built-in defaults.
  `Storage.config_layers` builds the chain; every resolver accepts a single
  `[_STORAGE]` dict or the vector of layers as `storage_config`.

### Changed

- **New `POOL_DEFAULTS`:** `$repo/datasets`,
  `$user_data_dir/datamanifest/shared/datasets` (the shared store doubles as the
  default read pool, so it self-populates), then the legacy
  `$user_data_dir/datamanifest/datasets` and `~/.cache/Datasets`.

Not mirrored (Python-side tooling, per the design's spec-normative/tooling split):
the `config` command, the generalized `push`/`pull` operands and git-remote
targets, `normalize`, `export`, `default_remote`.

## [0.27.0] - 2026-06-10 — spec-v4.4: `checksum` field

Tracks datamanifest.toml **`spec-v4.4`**. The bare `sha256` field is replaced by a
pooch-style **`checksum = "<algo>:<hex>"`** (`sha256:…`, `md5:…`; a bare hex value is
read as `sha256`). Additive and backward-compatible.

### Added

- **`checksum` (per-dataset field).** Carries its algorithm and is used for
  verification and change detection in that algorithm. Empty ⇒ computed (as `sha256:`)
  on first download. `hash_algo` / `hash_value` accessors expose the parts.

### Changed

- **`sha256` is a legacy alias.** A `sha256 = "<hex>"` key is read as
  `checksum = "sha256:<hex>"` and re-emitted as `checksum` on the next write (automatic
  in-place migration). `entry.sha256` still works as a property (reads the hex when the
  algorithm is sha256; assignment stores `checksum = "sha256:<hex>"`).
- **Verification honors the declared algorithm** and never rewrites a non-`sha256`
  digest to `sha256`. An algorithm this implementation cannot compute (the SHA stdlib
  has no md5) is preserved but **not** verified — a warning is emitted and the check is
  skipped rather than failing. (Full md5 verification would need an md5 dependency.)
- The state file (`.datamanifest-state.toml`) keeps its `sha256` record (local change
  detection), independent of the manifest's declared algorithm.

## [0.26.0] - 2026-06-06 — spec-v4.3: lazy access, object-store schemes, exact-or-error ids

Tracks datamanifest.toml **`spec-v4.3`** (and folds in `spec-v4.2`, which standardized the
read pools already shipped in 0.25.0). Adds an in-place **access mode**, normative
object-store URI schemes, and stricter identifier resolution.

### Added

- **`lazy_access` (per-dataset bool).** An **access mode**: open the `uri` *in place* via a
  loader instead of materializing a local copy — **no download, no checksum, no state-file
  record**, and maintenance never touches it. Requires a loader (a bare `lazy_access` with no
  loader is a **fail-loud error**); the access mechanism (streaming / mount / object-store
  filesystem) is the loader's concern. `get_dataset_path` / `download_dataset` return the `uri`;
  `load_dataset` hands it to the loader. Distinct from `skip_download` (a *management* mode);
  the two are independent.
- **Object-store URI schemes (normative set):** `s3://`, `gs://`, `gcs://`, `az://`, `abfs://`,
  `abfss://`, `adl://`, `gdrive://`. DataManifest.jl has **no built-in object-store backend**, so
  a *download* of one now errors clearly (pointing to `lazy_access` + a scheme-aware loader, or
  delegation to a peer tool) rather than failing obscurely or silently skipping. Such URIs are
  best used with `lazy_access` and a loader that reads the scheme. (HTTP/HTTPS keep their own
  dedicated download path.)

### Changed

- **Identifier resolution is exact-or-error.** Resolving a dataset by name / alias / `doi` that
  matches **more than one** dataset is now a fail-loud error naming the candidates, instead of a
  silent first-match (a shared `doi` across split archives made first-match a correctness
  footgun).
- Conformance pinned to spec tag **`spec-v4.3`** (fixtures byte-identical to `spec-v4.1`; only
  the JSON schemas changed for the new fields).

## [0.25.0] - 2026-06-05 — read pools (`datasets_pools` / `datacache_pools`)

Adds **read pools** — extra **read-only** locations probed for an already-present object before
downloading (or recomputing), so a dataset another project already fetched, or a `@cached`
result it already produced, is reused **in place** instead of re-obtained. A Python-parity
feature, **ahead of the spec** (which has no pool concept yet); the storage model is otherwise
unchanged.

### Added

- **`[_STORAGE].datasets_pools`** — a list of read-only path expressions probed for
  `<pool>/<key>` before a download. Host-composable via `_HOST`, env-overridable via
  `DATAMANIFEST_DATASETS_POOLS` (`pathsep`-separated). **Undefined** falls back to the
  well-known defaults (`$user_data_dir/datamanifest/datasets`, `~/.cache/Datasets`); an explicit
  **empty** list disables it. `Storage.datasets_pools(...)`.
- **`[_STORAGE].datacache_pools`** — the same for produced `@cached` artifacts, probed at
  `<pool>/<cachetype>[/<version>]/<hash>`. **Opt-in**: undefined ⇒ no pools (produced artifacts
  carry no content checksum, only their identity + `config.toml` validation).
  `Storage.datacache_pools(...)`.
- `Databases.resolve_from_pools(db, entry)` — the verified fetched-dataset pool probe: a
  declared `sha256` is checked against the pooled copy and a present-but-mismatched copy is
  **warned** about (the manifest checksum may be stale) rather than silently skipped, and the
  next pool is tried; the pool is never written to. `download_dataset` probes it after the
  recorded/derived location and before downloading, then **records** the adopted location in
  the state file. New downloads still go to `datasets_dir` (the gold standard). For an
  `extract`-ed dataset the **extracted** location `<pool>/<extract_path>` is probed (that is
  what it is read from, and what its `sha256` hashes), and read-first resolution applies at the
  dataset's natural extract level — so a zip/tar already extracted in a pool is reused too.

### Changed

- `@cached` resolution now searches **recorded artifact dir → derived dir → datacache pools**
  for a hit (read-first + opt-in pools), self-healing the state-file record with the location
  the artifact was found at. A miss still produces at the derived `datacache_dir` location.
- `resolve_existing_path` is now recorded → derived only; the old inline `~/.cache/Datasets`
  back-compat probe is subsumed by the built-in `datasets_pools` defaults (probed by
  `download_dataset`). The `datasets_pools` / `datacache_pools` list keys are reserved
  `[_STORAGE]` keys (excluded from user `$`-symbols).

## [0.24.0] - 2026-06-05 — spec-v4.1: the state file (`.datamanifest-state.toml`)

Tracks datamanifest.toml **`spec-v4.1`**, which unifies the produced-only `cached.toml` index
into a single, **git-ignored** **`.datamanifest-state.toml`** (the *state file*, `_META.schema
= 5`) that inventories **both** fetched datasets and produced artifacts. The split is now
explicit: `datasets.toml` is the committed **spec** (what to track + how to obtain it); the
state file is **regenerable local state** (where each object actually landed on this machine).
Storage layout is unchanged from 0.23.0.

### Changed — the state file (`DataManifest.CachedIndex`)

- **`cached.toml` → `.datamanifest-state.toml`** (git-ignored; added to `.gitignore`). Schema
  **5** has two namespaces: `[datacache."<cachetype>[@<version>]"]` (produced) and
  `[datasets."<key>"]` (fetched). `@` is the reserved version separator (a cachetype never
  contains `@`).
- **Produced instances map `hash → artifact directory`**, not params. The parameter key table
  is **no longer stored in the index** — it lives in each artifact's `config.toml` sidecar.
  Recipe-level `ref`/`format` are still refreshed on each register.
- **Fetched datasets are now inventoried.** The `datasets` namespace records each dataset's
  resolved `storage_path` and **actual** `sha256` (omitted under `skip_checksum`).
- **Legacy still read & migrated forward.** The `cached.toml` filename and schema 1–4 forms
  (flat, `[[produced]]` nested, params-body) are read and rewritten to the canonical
  `.datamanifest-state.toml` on the next write.
- New API: `register_dataset!` / `has_dataset` / `dataset_path_of` / `dataset_sha256_of` /
  `set_dataset_path!` / `remove_dataset!` / `dataset_records`, plus `instance_path_of` /
  `remove_instance!` and `locate_state`; `register!` takes a per-instance `storage_path`
  (was `params`). Writes are atomic (temp file + rename). `reachable_keys` is unchanged
  (`(cachetype, version, hash)`).

### Changed — fetch layer

- **Read-first resolution.** `resolve_existing_path` consults the state file's recorded
  `storage_path` **before** the derived `$datasets_dir/$key` rule — if those bytes are present,
  a *moved* dataset is found where it really lives. A (re)download still writes to the derived
  directive location (the gold standard); self-heal is additive and never deletes.
- **Recording on fetch.** A successful download records the resolved location + actual sha256
  into the state file (additive, concurrency-safe atomic write, best-effort). No-op for a
  manifest-less (in-memory, `persist=false`) database — the state file is defined relative to a
  manifest.
- The produced `metadata.toml` back-pointer `[origin].cached_toml` is renamed to
  **`[origin].state_file`**.

### Conformance

- Conformance re-pinned to spec tag **`spec-v4.1`**. The fixtures are byte-identical to
  `spec-v4` (the `inspect` fixture still exercises the legacy nested `cached.toml` read), so the
  suite continues to verify backward-compatible reading of the prior index shape.

## [0.23.0] - 2026-06-05 — spec-v4: two-folder storage model (BREAKING)

Tracks the **retagged datamanifest.toml `spec-v4`**, a **radical simplification** of the
storage model that **supersedes the scope-first model of 0.22.0** (which never shipped to
users beyond this branch). Storage reduces to **two folder fields**, local by default, with
nothing derived — the folder you set IS the location. The whole
scope/prefix/appname/derived-name/`store`-selector machinery introduced in 0.22.0 is removed.
The manifest *shape* stays additive, so `_META.schema` stays **1**; the break is again in
*where bytes land on disk*.

### Breaking — two-folder storage model

- **Two folder fields, local by default.** `[_STORAGE]` now has just `datasets_dir` (fetched
  datasets → `<datasets_dir>/<key>`, default `./datasets/`) and `datacache_dir` (produced
  cache → `<datacache_dir>/<cachetype>/[<version>/]<hash>/`, default `./cached/`). A relative
  folder is relative to the project root (`$repo`); an absolute, `~`, or `$symbol`-rooted path
  is used as written.
- **Scope/prefix/appname/selectors removed.** Gone: the `<root>/<scope>/<prefix>/<key>` layout,
  `[_STORAGE].scope` / `[_STORAGE._SCOPE]`, the per-dataset `scope` field, per-kind prefixes,
  the platformdirs-appname namespacing, the project-name default and "no guessing the scope"
  error, and the `store` selector. There is **no automatic scoping** — to centralize or share
  data you point a folder at a shared location in one explicit edit.
- **Bare predefined symbols.** `$user_data_dir` (= `platformdirs.user_data_dir()`, e.g.
  `~/.local/share`, with **no** `datamanifest` app segment), `$user_cache_dir` (`~/.cache`),
  and `$repo` (project root) interpolate in any path, alongside `$USER`/env and `~`. Any other
  bare `[_STORAGE]` key is a user-defined symbol, host-specific via `[_STORAGE._HOST."<glob>"]`.
  Resolution ladder (symbols and fields alike): `DATAMANIFEST_<NAME>` env →
  `[_STORAGE._HOST.<glob>].<name>` → base `[_STORAGE].<name>` → predefined default.
- **Per-dataset `storage_path` replaces `store` + `local_path`.** It is a path expression
  (default `$datasets_dir/$key`): containing `$key` ⇒ a tool-managed keyed location; an exact
  path without `$key` ⇒ user-managed, used verbatim and never touched by store maintenance.
- **Exactly two env overrides:** `DATAMANIFEST_DATASETS_DIR` and `DATAMANIFEST_DATACACHE_DIR`
  (user symbols override as `DATAMANIFEST_<NAME>`). The old `DATAMANIFEST_DIR` /
  `DATAMANIFEST_DATA_DIR` / `DATAMANIFEST_CACHE_DIR` / `DATAMANIFEST_SCOPE*` /
  `DATAMANIFEST_PREFIX_*` vars are gone.

### Changed — `cached.toml` / `@cached`

- **Recipes keyed by `(cachetype, version)`** (the `scope` and per-recipe `store` keys are
  dropped); reachability is `(cachetype, version, hash)`. `cached.toml` stays nested schema 2
  (`_META.schema = 2`); legacy flat schema 1 is still read and rewritten as schema 2.
- **Produced artifacts live under `datacache_dir`** at
  `<datacache_dir>/<cachetype>/[<version>/]<hash>/` (default `./cached/`).
- **`@cached` lost its `store=` and `scope=` options.** `cache_dir=` (a verbatim experiment
  folder that bypasses `datacache_dir`) and `version=` remain; `cachetype` still defaults to
  the importable name `Module.func`.

### Migration

- **Data moves to the local defaults.** With no `[_STORAGE]`, fetched datasets now land in
  `./datasets/<key>` and produced artifacts in `./cached/<cachetype>/…` under the project root.
  To keep data in a shared OS location, set `datasets_dir = "$user_data_dir/<name>"` (and
  `datacache_dir` likewise) — one explicit edit; there is no automatic scoping anymore.
- **Field renames.** A per-dataset `store` or `local_path` → `storage_path`; per-dataset and
  `[_STORAGE]` `scope` keys are dropped (no replacement — sharing is now an explicit folder
  target).

### Conformance

- Conformance re-pinned to the **retagged `spec-v4`**; the storage fixture asserts the
  two-folder model and `$`-symbol resolution. Implemented capabilities are unchanged
  (`lang-read`, `lang-write`, `shell-fetch`, `storage`, `binding-args`, `byte-identity`,
  `cache-produce`, `inspect`, `delegation`); only **`sync`** remains unimplemented.

## [0.22.0] - 2026-06-04 — spec-v4: scope-first storage layout (BREAKING)

Tracks datamanifest.toml **spec-v4**, a **breaking storage-layout revision** centered on
scope: everything is **project-scoped by default**, the project owns the namespace (the
library does not), and the scope is no longer guessed. The manifest *shape* is unchanged
(additive keys + a new path layout), so `_META.schema` stays **1**; the break is in *where
bytes land on disk*, versioned on the spec-tag axis. Existing stores need migration or a clean
re-fetch.

### Breaking — scope-first layout + project-scoped-by-default

- **Scope-first path layout.** Composition changes from `<root>/<prefix>/[<scope>/]<key>` to
  **`<root>/[<scope>/]<prefix>/<key>`** (scope outermost, then the per-kind prefix). A
  project's fetched data (`…/<scope>/datasets/…`) and produced artifacts (`…/<scope>/cached/…`)
  now live together under one `…/<scope>/` subtree.
- **Fetched datasets are project-scoped by default.** This **flips the spec-v3 datasets
  default** (was empty/shared) to match produced artifacts: the default scope is now the
  project name for both kinds. See the migration note below.
- **The project owns the namespace.** The built-in `$data`/`$cache` OS defaults now use the
  project scope as the **platformdirs appname** (`~/.local/share/<scope>/datasets/…`,
  `~/.cache/<scope>/cached/…`) — the literal `datamanifest` no longer appears as a directory,
  surviving only as the appname for the empty/global scope. For `$DATAMANIFEST_DIR`, `$repo`,
  and user-defined folders the root is bare and the scope is the **leading path segment**.

### Changed — three-level scope ladder, no guessing

- **Three-level scope ladder, one knob.** First-explicitly-set wins (an explicit `""` is a
  real value — the global/unscoped store — not "unset"): per-item (a dataset's `scope` field
  / a produced `scope=`) → `DATAMANIFEST_SCOPE_<KIND>` → `[_STORAGE._SCOPE].<kind>` →
  `DATAMANIFEST_SCOPE` → **`[_STORAGE].scope`** (new, project-wide) → the project name. The
  resolved scope drives both the on-disk path and the recorded `cached.toml` entry.
- **New per-dataset `scope` field** (datasets.toml) and **new project-wide `[_STORAGE].scope`**
  key (reserved). `scope = "cmip"` shares a heavy archive under a named pool; `scope = ""` is
  the unscoped/global store; omitted falls through to the layer default. There is no more
  `_META.project` — the project name only ever feeds the scope default.
- **No guessing the scope.** The built-in default is the project NAME — the Julia
  `Project.toml` `name` (not the uuid), found by walking up. If no project file declares a
  name, the tool **errors** and requires an explicit scope (`[_STORAGE].scope`,
  `DATAMANIFEST_SCOPE`, or a per-item `scope`) rather than synthesizing one (no path hash, no
  directory name) — mirroring the produced-dataset `cachetype` no-stable-identity rule. (An
  explicit `cache_dir=` in `@cached` still bypasses folder/prefix/scope entirely and needs no
  resolvable scope.)
- **Reserved prefix names** `datasets`/`cached` may not be used as a scope, so global
  empty-scope data at `<root>/datasets/…` never collides with a project subtree.

### Migration

- **Fetched data moved.** Downloads that previously landed at the shared, empty-scope location
  (`<root>/datasets/<key>`) now land under the project scope at
  `<root>/<scope>/datasets/<key>` (and `$data`/`$cache` now use the scope as the platformdirs
  appname, e.g. `~/.local/share/<project>/datasets/…`). Existing downloads still resolve via a
  read-only probe; to consolidate, re-fetch or `rsync`/move the old tree under the new
  `<scope>/` subtree (set `DATAMANIFEST_DIR` to keep everything under one root).
- **To keep sharing downloads across projects**, set `[_STORAGE._SCOPE].datasets = "<pool>"`
  (or `""` for the global store), or set `scope = ""` on the individual heavy datasets.
- **A project must now have a resolvable scope.** Working outside a project that declares a
  `Project.toml` `name` requires an explicit scope (`[_STORAGE].scope`, `DATAMANIFEST_SCOPE`,
  or a per-item `scope`); the tool errors rather than guessing.

### Conformance

- Conformance re-pinned to spec tag **`spec-v4`**; the storage fixture asserts all three scope
  levels and the scope-first layout. Implemented capabilities are unchanged (`lang-read`,
  `lang-write`, `shell-fetch`, `storage`, `binding-args`, `byte-identity`, `cache-produce`,
  `inspect`, `delegation`); only **`sync`** remains unimplemented.

## [0.21.0] - 2026-06-04 — spec-v3.7: reconciled produced-dataset / cache model

Tracks datamanifest.toml **spec-v3.7**, which reconciles the produced-dataset / cache model
with the implementation. The manifest `_META.schema` stays **1**; `cached.toml`'s own
`_META.schema` goes **1 → 2** (schema 1 is still read, always rewritten as 2). The cached
`project` keyword is renamed **`scope`**, `@cached` gains a `scope=` knob and an optional
`cachetype`, and the index now self-heals on cache hits.

### Changed — schema-2 nested `cached.toml` (`DataManifest.CachedIndex`)

- **`cached.toml` is now nested schema 2** (`_META.schema = 2`): a `[[produced]]` array of
  recipe tables keyed by `(scope, cachetype, version)`, each carrying recipe metadata
  (`ref`/`format`/`store`/`scope`) and one `[[produced.instances]]` per produced variation
  (its parameter `hash` + the `[produced.instances.params]` key table). Registering
  **accumulates** instances, so every parameterization of a recipe stays reachable instead of
  orphaning. The legacy flat **schema 1** is still **read** (each entry → a one-instance
  recipe) and rewritten as schema 2. The forbidden key `project` never appears in generated
  output.
- **`project` → `scope`.** The cached ownership knob is renamed everywhere: `scope` is a
  recipe-level field (parallel to a dataset's `store`); the `project` keyword is gone from
  `_META` and from all generated output.

### Changed — `@cached` cachetype + `scope=`

- **`cachetype` is now optional.** When omitted it defaults to the producing function's
  canonical *importable* name (`Module.func`), so it coincides with the recipe `ref`. A
  function with no stable importable identity (script / REPL / `eval` / notebook) still
  requires an explicit `cachetype`.
- **New `scope=` knob.** `scope` is ownership, resolved from the caller's project —
  isolation by default, sharing by opt-in — and never affects hit validity. Resolution
  ladder: explicit `scope=` (highest) → `DATAMANIFEST_SCOPE_CACHED` →
  `[_STORAGE._SCOPE].cached` → project id; `scope=""` selects one global, unscoped store. The
  scope is resolved once and drives both the on-disk path and the recorded entry.
- **Self-healing index on a cache hit.** A hit now re-registers a missing variation (so a
  deleted `cached.toml` repopulates as datasets are accessed) and refreshes a drifted recipe
  `ref`, best-effort and off the steady-state hot path. The on-disk `config.toml` stays the
  cache-validity authority; `metadata.toml` provenance stays **write-if-absent** (hits never
  re-stamp it) — only the index re-registers.
- **`[_STORAGE]` honored in the no-Database produce path.** A produced artifact reads the
  nearest manifest's `[_STORAGE]` (a plain TOML read, no fetch layer) even with no `Database`
  in scope, so produced and fetched data share one storage configuration; env overrides win,
  an explicit config wins over the manifest.
- The per-language RECOMMENDED default format is `jld2`; DataManifest.jl keeps shipping `jls`
  (stdlib `Serialization`) as the zero-dependency built-in self-saver, with `jld2`/`nc`/…
  available via `register_format!` — a documented, spec-permitted deviation (the default
  format is RECOMMENDED, not normative).

### Changed — scope-aware `inspect`

- **Reachability is now the full `(scope, cachetype, version, hash)` tuple** (new
  `scoped_keys`); `inspect_store` resolves `referenced` against the schema-2 index
  accordingly.

### Note — same-process conflict guard omitted in Julia

- The `(cachetype, version)` same-process conflict guard the spec **SHOULD**s is
  intentionally omitted here: precompilation makes a top-level recipe registry unreliable, and
  the spec explicitly permits narrowing/omitting it for such languages.

### Conformance

- Conformance re-pinned to spec tag **`spec-v3.7`**; the `cached_index` fixture follows the
  nested schema-2 form. Implemented capabilities are unchanged (`lang-read`, `lang-write`,
  `shell-fetch`, `storage`, `binding-args`, `byte-identity`, `cache-produce`, `inspect`,
  `delegation`); only **`sync`** remains unimplemented.

## [0.20.0] - 2026-06-03 — spec-v3.6: cross-language fetch + language-implicit & bare-shell bindings

Tracks datamanifest.toml **spec-v3.6**. Adds the cross-language fetch rung (capability
**`delegation`**), harmonizes binding forms (string|table everywhere), and adds
**language-implicit (bare) bindings** + the **bare language-agnostic `shell` field**.
`_META.schema` stays **1**. With this release, only **`sync`** remains unimplemented.

### New — language-implicit bindings (spec-v3.4/3.6) + bare `shell` field (spec-v3.5)

- **Bare `fetcher` / `loader`** on a dataset are read as the running tool's **own-language**
  binding (equivalent to `[<ds>._LANG.julia].fetcher`/`.loader`), and the top-level
  **`[_LOADERS]`** map is the language-implicit counterpart of `[_LANG.julia.loaders]`. The
  load/fetch ladders now consult them: own `_LANG.julia` rung → bare rung, with the explicit
  `_LANG.julia` binding **taking precedence**. A bare binding is **present** for Julia, so
  (spec-v3.6) it is treated exactly like an explicit `_LANG.julia` binding — **fail loud**: a
  resolution failure errors and a runtime error propagates, never a silent fall-through to a
  different loader/fetcher; the ladder only skips bindings that are **absent** for Julia.
  Bare bindings are **preserved verbatim** on write (never promoted into `_LANG.julia`).
- **Bare `shell`** is now a language-agnostic dataset field (the same command for every tool),
  the canonical form of the shell fetcher; the legacy `[<ds>._LANG.shell].fetcher` is still
  read. Fetch-ladder rung 2 runs `entry.shell` (else the legacy form).

### New — cross-language fetch (capability `delegation`)

- **Fetch ladder rung 3.** When a dataset's bytes can be produced only by a foreign-language
  fetcher (no own `_LANG.julia.fetcher`, no `_LANG.shell.fetcher`, no `uri`, but e.g. a
  `[<ds>._LANG.python].fetcher`), DataManifest.jl **delegates to the Python `datamanifest`
  CLI** when it is on `PATH`: it runs `datamanifest download <name>` (pointing the peer at the
  manifest via `DATAMANIFEST_TOML`), the peer materializes the result in the shared store
  (verifying `sha256`), and we read it back. Falls through to `uri` when the peer is absent,
  the call fails, or the dataset sets `delegate = false`. Native (Julia) and `shell` datasets
  never reach this rung; it applies to fetched datasets only (never produced `@cached` ones).

### Changed — spec-v3.3 binding harmonization (string|table everywhere)

- A **binding** (`fetcher`/`loader`) is now string *or* table at **every** site — including the
  project-wide `[_LANG.julia.loaders]` map, whose values may now be a `{ ref, args, kwargs }`
  table (a parameterized format-default loader), not just a `module:function` string.
- **Canonical write:** a ref-only binding (`{ ref = "M:f" }`) is normalized to the bare string
  `"M:f"` on write; a binding carrying `args`/`kwargs` is written as a table. (Per-dataset
  bindings already followed this; project loaders now do too.)

### Conformance

- Targets spec tag **`spec-v3.6`** and declares the **`delegation`** capability; validates
  the new `lang_implicit` fixture (bare bindings + `[_LOADERS]`) and the updated `multilang`
  fixture (bare `shell` field). 235 unit + 231 conformance tests pass.

### Docs

- README aligned with the spec's annotated [`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml) (linked, and the binding snippets drawn from it).

## [0.19.0] - 2026-06-03 — spec-v3: `cached.toml` index + store maintenance (`inspect`)

Completes the produce-or-load companion layer with the second half of spec-v3: the
`cached.toml` produced-dataset registry and the user-driven store-maintenance surface
(capability **`inspect`**), plus best-effort last-access tracking that is cross-tool with
the Python `datamanifest` CLI. `_META.schema` stays **1** (additive). Only `sync`
(cross-machine `push`/`pull`) remains deferred.

### New — `cached.toml` index (`DataManifest.CachedIndex`)

- **`cached.toml`** is the produced-dataset registry — the `Manifest.toml` analogue, sibling
  to `datasets.toml` — listing each produced dataset by its **portable** key (`cachetype` +
  `hash`), never an absolute path. It carries its own `[_META].schema = 1` (+ optional
  declared `project`); one table per dataset records `cachetype`, `hash`, `ref`, `format`,
  `store`, and (when non-empty) `project` and recipe `version`.
- **`CachedIndex`** + `read_index` / `read_index_or_empty` / `register!` / `index_keys` /
  `write_index` read, build, and write it with the same canonical key ordering as the
  manifest writer.
- **Register-on-produce.** `@cached` (and `save_cache` when given a `name`) now register the
  freshly-produced artifact into the project's `cached.toml` on a miss — `ref =
  "<module>:<function>"`, the project-id `project` scope, the recipe `version` when set — and
  the `metadata.toml` `[origin].cached_toml` back-pointer names that index. A cache hit
  registers nothing. The index defaults to `<project_root>/cached.toml`; a `cached_toml`
  kwarg overrides it. A new `name` macro argument overrides the registry name.

### New — store maintenance (capability `inspect`)

- **`inspect_store(db)`** is the composition root: it enumerates produced artifacts (the
  cache layer) and present fetched datasets (the fetch layer) as one list of field-bearing
  `CacheObject`s — `kind`, `key`/`hash`, `cachetype`, `version`, `scope`, `format`, `size`,
  `location`, `created`, `last_access`, `referenced` — resolving `referenced` from the
  project's `cached.toml`. Filter the result yourself and act with `delete_object` /
  `move_object` (both refuse anything that is not a produced `cached` artifact; there is **no
  automatic garbage collector** — deletion is always an explicit selection).
- **`enumerate_artifacts(cache_root)`** / `find_produced_artifacts` walk a `$cache` root and
  surface every produced artifact (a directory holding a `config.toml`), so a fetched
  `store="$cache"` dataset is never enumerated or deleted.

### New — last-access + usage log (best-effort, advisory; cross-tool with the Python CLI)

- **Last-access.** `last_access(path)` reports a produced artifact's last-read time, read
  purely from the filesystem at inspect time (the directory's `stat` access time) as an
  RFC-3339 UTC stamp — see the spec-v3.2 note below for the "never written on read" rule.
  Matches the Python `cache/_usage.py` contract.
- **Usage log.** A single `usage.toml` under `user_state_dir("datamanifest")` (overridable
  via `DATAMANIFEST_USAGE_LOG`) records every index path the cache layer reads/writes with a
  `last_seen` stamp (`usage_log_path` / `record_path!` / `read_usage` / `known_paths`).

### Changed — spec-v3.1 finite floats + spec-v3.2 last-access

- **Finite floats are valid hash inputs** (spec-v3.1). The parameter hash now accepts finite
  `Float64`/`Float32` anywhere in the key table, serialized via the **normative Python
  `json.dumps` float form** (`1.0`→`1.0`, `0.5`→`0.5`, `1e20`→`1e+20`, `1e-5`→`1e-05`) so the
  digest is cross-tool reproducible; `_python_float_repr` reproduces CPython's `repr`
  byte-for-byte. `NaN` / `±Inf` and nulls still raise. (Previously any float raised.)
- **Last-access is filesystem-derived and never written on read** (spec-v3.2). A cache hit no
  longer touches the artifact's access time; `last_access` reads the `stat` access time at
  inspect time (falling back to mtime when unreadable, possibly absent on `noatime`/network
  mounts), and the reader writes no sidecar/index/atime. `touch_last_access!` is removed —
  `created` (stamped once at produce time) is the always-available age signal.

### Conformance

- Targets spec tag **`spec-v3.2`**. The suite declares the **`inspect`** capability and
  validates the `cached_index` fixture (reading a `cached.toml`, checking its entries + rooted
  key set) and the `config_sidecar_float` fixture (finite-float hash reproduction).

## [0.18.0] - 2026-06-03 — spec-v3: storage roots/prefixes/scope + `@cached` produce-or-load

Tracks datamanifest.toml **spec-v3**: a breaking behavioral revision of the storage model
(it supersedes the spec-v2 model shipped in 0.17.0), plus the first half of the
produce-or-load companion layer (`cache-produce`). `inspect` (the `cached.toml` index +
maintenance) and `sync` are deferred to a follow-up.

### Breaking — storage roots, prefixes, and scope

- **Folder variables are bare top-level roots.** `$data` = `user_data_dir` (no `/Datasets`),
  `$cache` = `user_cache_dir`, `$repo` = `<project_root>`. The lowercase content prefix
  `datasets/` is applied by the layer, so a fetched dataset now lands at
  `<root>/datasets/[<scope>/]<key>` (previously `…/Datasets/<key>`).
- **New `DATAMANIFEST_DIR`** application base: when set, the default root of `$data` and
  `$cache` (so everything lands under `$DATAMANIFEST_DIR/datasets/…` and `…/cached/…`).
- **New `[_STORAGE._PREFIX]` / `[_STORAGE._SCOPE]`** tables and `DATAMANIFEST_PREFIX_<KIND>` /
  `DATAMANIFEST_SCOPE_<KIND>` env vars. The **scope** partition controls sharing — empty for
  `datasets` (shared), the project id for `cached` (project-isolated).
- **`_PROFILE` is shelved**: reserved and preserved verbatim, no longer resolved (host
  specificity is covered by the auto-matched `_HOST`).
- **Read-only migration probe.** Existing 0.17.0 downloads under `…/datamanifest/Datasets`
  still resolve (probed read-only, alongside the pre-v1.1 `~/.cache/Datasets` probe), so
  nothing needs re-downloading; the probe is skipped when `DATAMANIFEST_DATA_DIR` or
  `DATAMANIFEST_DIR` is set.

### New — produce-or-load (`@cached`, `DataManifest.Cache`, capability `cache-produce`)

- **`@cached cachetype=… key=(args -> (;…)) [ext=] [basename=] [version=] [store=]`** wraps a
  **keyword-only** function with transparent disk caching: a `cached::Bool=true` escape
  hatch, `_`-prefixed runtime knobs excluded from the hash, and a `_metadata_extras` audit
  channel merged into the sidecar. (The macro is a non-normative ergonomic surface, ported
  from LGMIO's `@cached`.)
- **Parameter-hash keying.** The key is the SHA-256 of the **canonical JSON (JCS, RFC 8785)**
  of the hash-affecting keyword parameters — cross-tool reproducible (reference vector
  `83425a30…`). Hash inputs are restricted to strings/integers/booleans/arrays/objects;
  **floats and nulls are a hard error**, and positional arguments are rejected (produced
  datasets are keyword-only).
- **Self-describing artifacts** at `<folder>/cached/[<scope>/]<cachetype>/[<version>/]<hash>/`:
  the produced artifact plus `config.toml` (re-hashable key table + `[_META]`) and
  `metadata.toml` (provenance: `created`/`tool`/`host`/`user`/`[git]`, write-if-absent),
  materialized via the shared safe-materialization primitive. Default `store = "$cache"`.
- **Artifact format registry.** `jls` (stdlib `Serialization`) is built in; other formats
  (`nc`/`jld2`/…) register a `(save, load)` pair via `DataManifest.Cache.register_format!`
  (the produced byte format is per-tool, not cross-language).
- Conformance pin advanced to **`spec-v3`**; the `config_sidecar` fixture (param-hash
  re-check) passes. `Dates` and `Serialization` are now declared dependencies.

## [0.17.0] - 2026-06-03 — spec-v2: `$`-folder-variable storage model

Implements the spec-v2 storage-model revision (datamanifest.toml `spec-v2` /
`spec-v2.1`). The produce-or-load companion layer (`cache-produce` / `cache-gc`)
is **not** part of this release — it remains a separate, follow-up concern.

### Breaking — storage selectors are now `$`-folder references

- **`store` and the new `[_STORAGE].default` are `$`-folder selectors.** A folder
  is referenced as a `$`-variable: built-in `$data` / `$cache` / `$repo`, plus any
  user-defined folder declared in `[_STORAGE]` (e.g. `scratch = "…"` → `$scratch`).
  A selector may carry a literal sub-path: `store = "$cache/derived"` keys the
  dataset under `<cache_root>/derived/<key>`. `store` defaults to the project-wide
  `[_STORAGE].default`, which itself defaults to `$data`.
- **Hard migration off bare names.** The spec-v1.1 bare form (`store = "cache"`) is
  no longer valid. Bare built-in names (`data`/`cache`/`repo`) are **auto-upgraded**
  to `$`-form on read with a one-time deprecation warning and rewritten in `$`-form
  on the next write; any other bare value (including the removed `mount` store) is
  rejected with a guiding error. `[_STORAGE]` keys themselves stay bare — they are
  folder *definitions*, not references.
- **`mount` removed.** spec-v2's locations-only model has no home for
  never-materialized in-place access; the `mount` store is gone (deferred to a
  future revision).

### Storage model

- **One resolution ladder for every folder variable** (built-in and user-defined):
  `DATAMANIFEST_<NAME>_DIR` env → `[_STORAGE._PROFILE.<profile>].<name>` →
  `[_STORAGE._HOST.<glob>].<name>` → `[_STORAGE].<name>` → built-in default
  (`data`/`cache`/`repo` only; an undefined user folder is an error). Host- and
  profile-specificity live entirely in resolving the variable.
- **Two value kinds.** *Selectors* (`store`, `default`) are `$`-folder references;
  *path expressions* (`[_STORAGE]` values, `local_path`) are full paths that
  interpolate `$`-folder variables, `$USER`/env vars, and `~`. `local_path` is now
  expanded as a path expression, so a host-specific exact path is expressed
  portably as `local_path = "$scratch/exact/file.nc"`.
- Built-in default roots are unchanged from spec-v1.1 (platformdirs
  `user_data_dir`/`user_cache_dir` + `/Datasets`, and `<project_root>/datasets`),
  so no dataset needs re-downloading. The read-only legacy probe of the pre-v1.1
  `$XDG_CACHE_HOME/Datasets` folder is retained.

### Fixes

- **Round-trip stability for key-less datasets.** A produced/`local_path`-only
  dataset no longer serializes a content-free `uri = "://"`, which previously
  re-parsed to a `":"` key and could collide two such datasets on read.

### Conformance

- Conformance pin advanced to spec tag **`spec-v2.1`** (fixtures re-hashed); the
  storage fixture assertions follow the spec-v2 storage schema (`$`-form selectors,
  the `default` selector, and the `data`/`cache`/`repo` + user folder-variable
  namespace). `cache-produce` / `cache-gc` fixtures are skipped (capability not
  declared by this core tool).

## [0.16.0] - 2026-06-02 — spec-v1.1: storage, parameterized bindings, verify-once, canonical output, legacy fix

### New features

- **Cross-tool byte-identical output (opt-in).** `write(db, path; canonical=true)`
  pipes the serialized manifest through the Python `datamanifest format` CLI so
  Julia and Python emit byte-for-byte identical files. Optional and graceful: if
  the peer CLI is not on `PATH` (or fails), it falls back to native TOML — which
  is already semantically identical (same keys, same canonical order), differing
  only in TOML-library formatting. Default behavior is unchanged.

### Fixes

- **Legacy datasets are found again (storage migration).** spec-v1.1 moved the
  default `data` store to `platformdirs.user_data_dir` (under a `datamanifest/`
  namespace), which orphaned datasets downloaded by older versions in the flat
  `$XDG_CACHE_HOME/Datasets`. Read resolution now probes that legacy folder
  **last and read-only**, so existing downloads resolve again; new fetches still
  go to the new store. A one-time warning points at the manual-migration escape
  hatch (`DATAMANIFEST_DATA_DIR`, or `rsync`). Also wires the cross-store read
  resolution (`repo`→`data`→`cache`) into the download/load path, which was
  defined but unused.

### Storage & bindings (spec-v1.1)

- **Storage model (`store` field + `[_STORAGE]`)**: each dataset may declare a
  `store` of `data` (default), `cache`, `repo`, or `mount` (parsed verbatim; not
  yet mounted). Default roots match Python's `platformdirs` so peer tools resolve
  the same dataset to the same on-disk path.
- **Default download location changed** (behavior change): the `data` store
  default is now `$XDG_DATA_HOME/datamanifest/Datasets` (Linux) rather than
  `$XDG_CACHE_HOME/Datasets`. Existing cached downloads are not moved
  automatically. Set `DATAMANIFEST_DATA_DIR` to your old cache path to keep
  resolving existing files without re-downloading.
- **`[_STORAGE]` resolver**: per-store root-path precedence —
  `DATAMANIFEST_<STORE>_DIR` env-var → `_PROFILE.<name>` (when
  `DATAMANIFEST_PROFILE` set) → first matching `_HOST.<glob>` → `[_STORAGE]`
  base → platformdirs default. `~` and `$VAR` expanded.
- **Read-order resolution**: `resolve_existing_path` searches `repo → data →
  cache` and returns the first existing complete entry, enabling seamless
  promotion of a dataset from one store to another.
- **Safe materialization**: fetchers write to `<target>.tmp` and atomically
  rename to `<target>` on success; a `.complete` marker (`<file>.complete` or
  `<dir>/.complete`) is created. A missing marker is treated as absent; a killed
  write leaves no partial entry.
- **Verify-once integrity** (Theme A): checksum is computed only when actually
  (re-)fetching. A present, complete entry with a stored `sha256` is not
  re-hashed on every `load_dataset` call.
- **Parameterized bindings** (`{ ref, args, kwargs }`): `fetcher`/`loader` in
  `[<ds>._LANG.julia]` may be a table `{ ref = "Mod:fn", args = [...], kwargs =
  {...} }` instead of a bare string. `$var` substitution (`$download_path`,
  `$path`, `$key`, `$uri`, etc.) is applied to string values in `args`/`kwargs`
  at execution time; the resolved function is called as `ref(args...; kwargs...)`.
  Bare-string bindings are unaffected.
- **`shell=` migration**: `DataManifest.migrate` now also converts a flat
  per-dataset `shell = "<cmd>"` field into `[<ds>._LANG.shell].fetcher`.
- **Conformance re-pinned to `spec-v1.1`**: implemented capabilities are now
  `lang-read`, `lang-write`, `shell-fetch`, `storage`, `binding-args`,
  `byte-identity`. The conformance suite adds assertions for the `storage` block,
  `binding_args` block, and self-consistent byte-identity (serialize → parse →
  serialize is byte-stable).

### Internal

- `DatasetEntry` gains `store::String = ""`.
- `Database` gains `storage_config::Dict{String,Any}` populated from
  `[_STORAGE]` (verbatim copy stays in `extra` for lossless round-trip).
- New `src/Storage.jl` module: pure `store_root(store; …) → String` resolver.
- `DatasetEntry` gains `lang_julia_fetcher_args`, `lang_julia_fetcher_kwargs`,
  `lang_julia_loader_args`, `lang_julia_loader_kwargs` for the parameterized
  binding form.

---

## [0.15.0] - 2026-06-02 — schema v1 / `_LANG` namespace

### New features

- **Schema v1 (`_META.schema = 1`)**: manifests can now declare bindings as `module:function` references in a `_LANG.julia` subtable instead of inline Julia code. The inline `julia=`/`loader=` execution path is retained but gated to v0/legacy files (schema absent).
- **`_LANG.julia` read/write**: per-dataset `[<ds>._LANG.julia].fetcher` / `.loader` refs and the manifest-level `[_LANG.julia.loaders]` format→ref map are parsed into the model on read and regenerated verbatim on write.
- **v1 fetch ladder**: `_LANG.julia.fetcher` ref → `_LANG.shell.fetcher` template → `uri`/`uris` → error. Delegation to peer CLIs is not yet implemented.
- **v1 load ladder**: own `_LANG.julia.loader` ref → manifest `[_LANG.julia.loaders][format]` → built-in format default → error. Loaders never spawn a subprocess.
- **`module:function` ref resolver**: refs are resolved at runtime via `using Module` + `getfield(Module, :function)` — no `eval` or `include_string`.
- **Lossless multi-language round-trip**: foreign `_LANG.<other>` subtrees (e.g. `[bar._LANG.python]`) and unknown `_*` top-level tables survive every read→write cycle verbatim. Only `_LANG.julia` is regenerated.
- **`DataManifest.migrate(path)`**: opt-in v0→v1 migration. Moves ref-shaped `julia=`/`loader=` fields and `[_LOADERS]` ref entries into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]` and sets `_META.schema = 1`. Inline code is preserved verbatim with a log note. Idempotent.
- **Read-time deprecation note**: a one-time warning is emitted when a legacy `[_LOADERS]` or per-dataset `julia=`/`loader=`/`julia_modules`/`julia_includes` is read.
- **Shared conformance suite**: `test/runtests.jl` downloads the spec tarball from tag `spec-v1.0`, verifies every fixture file against a pinned per-file sha256 map (`test/conformance_pin.toml`), and runs the fixtures covered by this tool's declared capabilities: `lang-read`, `lang-write`, `shell-fetch`.

### Internal

- `DatasetEntry` gains `lang_julia_fetcher::String` and `lang_julia_loader::String`.
- `Database` gains `lang_julia_loaders::Dict{String,String}`, `schema::Union{Int,Nothing}`, and `extra::Dict{String,Any}`.
- `DatasetEntry` gains `extra::Dict{String,Any}` for passthrough of unknown per-dataset keys and foreign `_LANG.*` subtrees.

## [0.14.1] - 2026-05-21

### Changed

- **`local_path` semantics narrowed to "location override"** (correcting v0.14.0 behavior, which conflated location and download policy). `local_path` now only changes where the dataset's local file lives — the cache-hit/download/checksum/extraction pipeline is otherwise unchanged. Cache miss falls through to the normal URI-driven download, writing the result to `local_path`. To declare a user-managed file that DataManifest must never try to download (Cloudflare, click-through agreements, manual logins), pair `local_path` with `skip_download = true`.

### Improved

- **Generic missing-file error**: `download_dataset` now produces a clear message ("Dataset file or folder not found at `<path>`. The documented URI is `<uri>`.") when the expected file is missing after the download/skip step. Applies uniformly whether the file should have been fetched, was declared via `local_path`, or was bypassed via `skip_download = true`.

### Documentation

- Clarified that the URI's role can be purely informative when downloads are handled by `shell`/`julia` code, `local_path`, or `skip_download = true`. DataManifest does not enforce URI strictness.
- `skip_download`: noted that `local_path` is the recommended option for new code when declaring a user-managed local file.

## [0.14.0] - 2026-05-21

### New features

- **`local_path` field on `DatasetEntry`**: declares a user-managed location for the dataset, distinct from DataManifest's own cache (`datasets_folder` / `key`). Relative paths are resolved against the directory of `Datasets.toml` (git-portable, in-repo data files); absolute paths are used as-is (NAS mounts, scratch volumes). Self-documenting alternative to `skip_download = true`, which overloaded `uri` as a path.

## [0.13.1] - 2026-05-04

### New features

- **`description` field on `DatasetEntry`**: free-form prose attached to a dataset entry, written/read alongside the other keys in `Datasets.toml`. Use this for rationale or provenance notes that would otherwise be lost as standalone TOML comments when the manifest is rewritten.

## [0.12.2] - 2025-02-14

### Fixed

- **julia download code**: Execution context now correctly imports **julia_modules** in `[_LOADERS]`

## [0.12.1] - 2025-02-12

### Fixed

- **julia download code**: Execution context now injects `uri`, `key`, `version`, `doi`, `format`, `branch` (same names as shell template placeholders). Code like `error("Download from $uri into $download_path")` no longer raises `UndefVarError: uri not defined`.
- **CSV default loader**: Use `comment="#"` (string) for CSV.jl; newer CSV.jl expects `Union{Nothing,String}` for `comment`, not `Char`.


### Documentation

- Documented variables available in `julia` download code (`download_path`, `project_root`, `entry`, `uri`, `key`, etc.) and the `human` option.

### Tests

- Shell template: test that `$uri` and `$download_path` (escaped) are expanded correctly.
- julia download: test that `uri`, `download_path`, `key`, `doi` are in scope and usable in string interpolation.

## [0.12.0] - 2025-02-11

### New features

- **Identify format** : more permissive format identification (anythhing after dot)
- **New format-based default loaders**: `csv`, `parquet`, `yaml`, `nc`, `toml`, `json`... and nc variant (`dimstack`)
- **Default archive loaders**: Built-in loaders for `zip`, `tar`, and `tar.gz` (when `extract=false`) that extract to a temporary directory and return its path. Optional dependencies: ZipFile, Tar, CodecZlib; loaded on use.
- **Lazy loader compilation**: `register_loaders` only stores loader config; loaders are compiled on first use. This avoids circular dependencies when a package that uses DataManifest is listed in `julia_modules`. Use **`validate_loaders(db)`** or **`validate_loader(db, name)`** to compile (and validate) loaders explicitly.
- **Loader-from-TOML**: Specifying `loader = "..."` (or a registry name / format default) in datasets.toml is fully supported. If a world-age error occurs when calling a manifest-defined loader, the call is retried via `Base.invokelatest`.
- **Reference format `A[.B.C].func`**: Loader strings that look like module paths (e.g. `SomeModule.loader_func`) are resolved at runtime by importing the top-level module and using a getfield chain. No need to list the module in `julia_modules` for this path.
- **load_dataset(..., loader=callable or string reference to toml loader)** is supported

### Changed

- **World-age handling**: Loader calls try a direct invoke first; on world-age error, the call is retried with `Base.invokelatest`.

### Breaking

- **DataBase** module renamed to **Databases** (plural, matches Julia convention e.g. DataFrames/DataFrame). Code referencing `DataManifest.DataBase` must use `DataManifest.Databases`. Type names `Database` and `DatasetEntry` unchanged.
- [_loaders] renamed to [_LOADERS]

### Tests

- Tests for loaders (when optional dependencies are installed).
- Tests for loader-from-TOML: entry.loader string, registry name, format default, and alias (md → txt) are exercised without passing `loader=` to `load_dataset`.


## [0.11.0] - 2025-02-11

### New features

- **julia**: Run Julia code in an isolated module instead of a subprocess (takes precedence over `shell` when set).
- **julia_modules**: List of module names; each is loaded with `using X` in the same isolated module before running `julia`.

### Breaking

- `command` renamed to `shell`, `julia_cmd` renamed to `julia`. Update TOML and keyword arguments accordingly.

### Internal

- Reorganize code into four modules to reduce cross-module linkage.
  - **Config**: Paths, logging, SHA, `get_default_toml`, `project_root_from_paths`.
  - **Databases**: Types, path/URI helpers, and registry.
  - **PipeLines**: Download and load pipeline plus default loaders.
  - **DataManifest**: Includes Config, Databases, PipeLines; re-exports public API; extends `Base.write`.
  Public API unchanged; `Loaders` is an alias for `PipeLines`.

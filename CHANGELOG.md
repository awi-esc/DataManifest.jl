# Changelog

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

# Changelog

## [Unreleased] — schema v1 / `_LANG` namespace

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

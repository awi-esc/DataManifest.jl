# Changelog

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

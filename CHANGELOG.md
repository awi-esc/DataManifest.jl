# Changelog

## [0.11.0] - 2025-02-09

### New features

- **julia**: Run Julia code in an isolated module instead of a subprocess (takes precedence over `shell` when set).
- **julia_modules**: List of module names; each is loaded with `using X` in the same isolated module before running `julia`.

### Breaking

- `command` renamed to `shell`, `julia_cmd` renamed to `julia`. Update TOML and keyword arguments accordingly.

### Internal

- Reorganize code into four modules to reduce cross-module linkage.
  - **Config**: Paths, logging, SHA, `get_default_toml`, `project_root_from_paths`.
  - **DataBase**: Types, path/URI helpers, and registry.
  - **PipeLines**: Download and load pipeline plus default loaders.
  - **DataManifest**: Includes Config, DataBase, PipeLines; re-exports public API; extends `Base.write`.
  Public API unchanged; `Loaders` is an alias for `PipeLines`.

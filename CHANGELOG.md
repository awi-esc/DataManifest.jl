# Changelog

## Changes since v0.10.2 

- **julia_cmd**: New `DatasetEntry` field to run Julia code in an isolated module instead of a subprocess (avoids reloading heavy modules; takes precedence over `command` when set).
- **julia_modules**: New `DatasetEntry` field: list of module names; each is loaded with `using X` in the same isolated module before running `julia_cmd`.


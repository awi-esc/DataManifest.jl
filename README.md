<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="datamanifest.toml" height="76">
  </picture>
</p>

# DataManifest.jl

[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)
[![docs](https://img.shields.io/badge/docs-perrette.github.io%2Fdatamanifest-blue)](https://perrette.github.io/datamanifest/)

DataManifest.jl keeps track of the datasets a scientific project depends on.
You declare each dataset — its URL or git repository, an optional checksum, a
format — in a **manifest**: a plain `datamanifest.toml` file that lives in
your repository. DataManifest.jl then downloads, verifies, extracts and loads
the data on demand, and can cache your own computed results with the same
machinery. The same manifest is read by a sibling Python tool, which also
provides a `datamanifest` command-line interface.

**Full documentation:** <https://perrette.github.io/datamanifest/> — the
central site for the whole ecosystem (concepts, storage model, manifest
format, CLI), including the [Julia API
reference](https://perrette.github.io/datamanifest/julia-api/) mirrored from
this repository.

DataManifest.jl is still actively developed, with breaking changes possible
until v1.0.0.

## Installation

```julia
using Pkg
Pkg.add("DataManifest")
```

Development version:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

## Quick start

In an activated project (`using Pkg; Pkg.activate(...)`):

```julia
using DataManifest

db = read_dataset("datamanifest.toml")
add(db, "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path(db, "co2")
```

`add` downloaded the Mauna Loa CO₂ record and wrote one entry to
`datamanifest.toml`, next to your `Project.toml`. The manifest is a plain TOML
file you can read and edit by hand:

```toml
[co2]
checksum = "sha256:0058b3788040b5c27b2b5c1dd6d26226b7e4deef85e34c153e64806c37df7c75"
uri = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"
```

By default the data itself is stored outside your repository, in a shared
folder under your user data directory (on Linux,
`~/.local/share/datamanifest/shared/datasets`), so several projects can reuse
the same downloads. `get_dataset_path` returns the resolved on-disk path.

## What to commit to git

Commit **`datamanifest.toml`** — it is the recipe: what to fetch and how to verify
it. Everything else stays out of git:

- the downloaded data lives outside the repository (see above);
- the `.datamanifest/` directory, which records where each file landed on
  *this* machine (`state.toml`) and holds per-machine configuration, is
  git-ignored automatically.

A collaborator who clones your repository runs `download_datasets()` to fetch
everything declared in the manifest.

## Documentation

Everything shared across the ecosystem — the storage and configuration model,
the manifest format, the use cases, and the `datamanifest` CLI — lives on the
central site: **<https://perrette.github.io/datamanifest/>**.

Julia-specific reading in this repository:

- [docs/doc.md](docs/doc.md) — the walkthrough, from everyday usage to
  advanced topics.
- [docs/api.md](docs/api.md) — the API reference (every function and field).
- [docs/caching.md](docs/caching.md) — the `@cached` produce-or-load macro.
- [docs/language-bindings.md](docs/language-bindings.md) — fetchers and
  loaders in Julia.

## Conformance

The manifest format is defined by a shared specification,
[datamanifest.toml](https://github.com/perrette/datamanifest.toml) (currently
tag `spec-v5.6`), common to this package and the sibling Python tool
([`datamanifestpy`](https://pypi.org/project/datamanifestpy/) on PyPI).
Implemented capabilities: `lang-read`, `lang-write`, `shell-fetch`, `storage`,
`binding-args`, `byte-identity`, `cache-produce`, `inspect`, `delegation`.
Only `sync` (cross-machine `push`/`pull`) is not implemented — use the Python
CLI for that.

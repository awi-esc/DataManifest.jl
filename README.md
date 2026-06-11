<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="datamanifest.toml" height="76">
  </picture>
</p>

# DataManifest.jl

[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)
[![docs](https://img.shields.io/badge/docs-awi--esc.github.io%2FDataManifest.jl-blue)](https://awi-esc.github.io/DataManifest.jl/)

DataManifest.jl keeps track of the datasets a scientific project depends on.
You declare each dataset — its URL or git repository, an optional checksum
(a hash of the file contents, used to verify a download), a format — in a
**manifest**: a plain `Datasets.toml` file that lives in your repository.
DataManifest.jl then downloads, verifies, extracts and loads the data on
demand, and can cache your own computed results with the same machinery. It
works with data repositories such as PANGAEA or Zenodo and with git hosts such
as GitHub, and the same manifest is read by a sibling Python tool, which also
provides a [command-line interface](#manage-your-data-from-the-shell).

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

DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")
```

`add` downloaded the Mauna Loa CO₂ record and wrote one entry to
`Datasets.toml`, next to your `Project.toml`. The manifest is a plain TOML
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

Commit **`Datasets.toml`** — it is the recipe: what to fetch and how to verify
it. Everything else stays out of git:

- the downloaded data lives outside the repository (see above);
- the `.datamanifest/` directory, which records where each file landed on
  *this* machine (`state.toml`) and holds per-machine configuration, is
  git-ignored automatically.

A collaborator who clones your repository runs `download_datasets()` to fetch
everything declared in the manifest.

## Loading datasets

`get_dataset_path` gives you a path; `load_dataset` goes one step further and
returns the loaded object. For that, the dataset (or its file format) needs a
**loader**: a reference to a Julia function, written as `"Module:function"` in
the manifest. For example, with `csv = "CSV:read"` declared as a project-wide
loader, `load_dataset("co2")` returns the parsed table directly. How loaders
are declared and resolved is covered in
[docs/language-bindings.md](docs/language-bindings.md).

## Caching computed results (`@cached`)

The same storage machinery can cache the result of an expensive computation,
keyed by its parameters:

```julia
using DataManifest

@cached key=(a -> (; a.grid)) function load_anomaly(; grid::String = "5x5")
    # … expensive computation …
    return result
end

load_anomaly(; grid="5x5")               # computes once, then loads from disk on repeat calls
load_anomaly(; grid="5x5", cached=false) # bypass the cache: run the body, no disk I/O
```

Each distinct parameter combination is stored separately under a per-project
cache directory (by default
`$user_cache_dir/datamanifest/projects/$project/cached`), in a self-describing
layout. Serialization defaults to the dependency-free `jls` built-in (Julia's
standard `Serialization`); other formats (`nc`, `jld2`, …) can be registered
with `DataManifest.Cache.register_format!`, and a `version=` argument lets you
deliberately invalidate old results. The full behaviour — cache key, artifact
layout, `cachetype` identity — is described in
[docs/caching.md](docs/caching.md).

## Choosing where data is stored

Storage comes down to two folders: `datasets_dir` (fetched data) and
`datacache_dir` (`@cached` results). The defaults are the machine-global
shared store and the per-project cache described above; both can be changed,
with `$`-symbols (placeholders like `$USER` expanded at resolution time) and
per-host overrides. Set them in the committed `[_STORAGE]` section of the
manifest, or per machine in the git-ignored `.datamanifest/config.toml` or in
`~/.config/datamanifest/config.toml`:

```toml
[_STORAGE]
datasets_dir = "datasets"                # repo-local layout, if you prefer it

[_STORAGE._HOST."login*.hpc.edu"]
datasets_dir = "/scratch/$USER/data"     # host-specific override
```

Path expressions, the order in which settings are resolved, per-dataset
overrides, **read pools** (extra directories searched read-only, so a project
can reuse data another project already fetched), and the state file that makes
moved data recoverable are documented in [docs/storage.md](docs/storage.md).

## Manage your data from the shell

DataManifest.jl has no command-line interface of its own. The manifest is
language-neutral, and the Python implementation's `datamanifest` CLI manages
the same file (it auto-detects `Datasets.toml`): adding, listing, verifying,
repairing and syncing data all work from the shell, without touching your
Julia code.

```bash
pip install datamanifestpy
```

```bash
datamanifest list                 # what's tracked, and where it lives
datamanifest add https://host/path/file.nc
datamanifest verify               # re-check every checksum
datamanifest refresh --scan       # repair: reassociate data found on disk
datamanifest push co2 user@hpc    # rsync a dataset to another machine
datamanifest storage              # where data goes on this host
```

See the [Python README](https://github.com/perrette/datamanifest#readme) for
the use cases and the
[CLI reference](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
for every command. The two tools also cooperate at fetch time: a dataset whose
fetcher is written in Python is fetched by delegating to this CLI (and the
Python tool can delegate to Julia in turn) — see
[cross-language fetch](docs/language-bindings.md#the-ladders).

## One manifest, several languages

A dataset can carry per-language bindings under a `_LANG` table: a
**fetcher** (a function that downloads or produces the data) and a loader,
each given as a `Module:function` reference — never inline code. Each
implementation runs its own bindings and preserves the others verbatim, so
one manifest serves a mixed Julia/Python project:

```toml
[_LANG.julia.loaders]            # project-wide format → loader defaults
csv = "CSV:read"
nc  = "NCDatasets:Dataset"

[ocean_temp]
uri = "https://example.com/ocean_temp.nc"
format = "nc"

[ocean_temp._LANG.julia]
loader = "MyClimate:load_argo"   # per-dataset override

[ocean_temp._LANG.python]
loader = "myclimate.load:argo"   # Python's binding; Julia never touches it
```

A single-language project can use bare `fetcher` / `loader` / `shell` fields
instead of the `_LANG` table. Resolution order, parameterized bindings
(`{ ref, args, kwargs }`), opening remote objects in place without downloading
(`lazy_access`), and cross-language fetch are covered in
[docs/language-bindings.md](docs/language-bindings.md).

## Explicit and manifest-less databases

The quick start relied on the activated Julia project to locate the manifest.
You can instead build the `Database` object explicitly:

```julia
db = Database("Datasets.toml", "my-data-folder")
DataManifest.add(db, "https://…"; name="…")
path = get_dataset_path(db, "co2")
```

Library code that only wants checksummed downloads into a folder it controls
can skip the manifest entirely with `persist=false`: no `Datasets.toml`, no
state file, nothing written but the data. The folder accepts the same
`$`-symbols as the storage configuration (`raw"…"` keeps Julia from
interpolating the `$`):

```julia
db = Database(datasets_folder=raw"$user_data_dir/mylib", persist=false)
DataManifest.add(db, "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path(db, "co2")   # → ~/.local/share/mylib/gml.noaa.gov/…/co2_annmean_mlo.csv
```

## Documentation

Browsable site: **<https://awi-esc.github.io/DataManifest.jl/>**. The same pages in the repo:

- [docs/doc.md](docs/doc.md) — the long-form walkthrough; [docs/api.md](docs/api.md) — the API.
- [docs/configuration.md](docs/configuration.md) — every configuration variable, its scopes, and how values are resolved.
- [docs/storage.md](docs/storage.md) — storage model, read pools, state file, maintenance.
- [docs/caching.md](docs/caching.md) — the `@cached` layer in full.
- [docs/language-bindings.md](docs/language-bindings.md) — `_LANG`, resolution order, `lazy_access`.

## Conformance

The manifest format is defined by a shared specification,
[datamanifest.toml](https://github.com/perrette/datamanifest.toml) (currently
tag `spec-v5.5`), common to this package and the sibling Python tool
([`datamanifestpy`](https://pypi.org/project/datamanifestpy/) on PyPI). A
complete annotated example manifest lives in the spec repository
([`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)).
Implemented capabilities: `lang-read`, `lang-write`, `shell-fetch`, `storage`,
`binding-args`, `byte-identity`, `cache-produce`, `inspect`, `delegation`.
Only `sync` (cross-machine `push`/`pull`) is not implemented — use the Python
CLI for that.

## Related projects

DataManifest.jl is one member of a multi-language family built on the shared
TOML schema: the same `Datasets.toml` is read by sibling tools in other
languages via the `_LANG` namespace, so a Julia and a Python project can share
one data declaration without stepping on each other. Configuration stays
declarative: custom logic lives in references to external Julia code
(`Module:function`) rather than code embedded in the config file.

**The DataManifest family:**

- [`perrette/datamanifest.toml`](https://github.com/perrette/datamanifest.toml) — the shared TOML schema; the common contract every implementation reads.
- [`perrette/datamanifest`](https://github.com/perrette/datamanifest) — the Python implementation, sharing the same `Datasets.toml` via the `_LANG` namespace; also the home of the [CLI](#manage-your-data-from-the-shell).

**Julia alternatives** (single-language). As a rule of thumb: if you only need
code-driven download-and-checksum, DataDeps.jl is lighter; if you want a rich
declarative data ecosystem, DataToolkit.jl is richer; DataManifest.jl targets
multi-dataset, multi-language scientific projects that want the whole
dependency declaration — and its derived-data cache — in one shareable file.

- [`DataDeps.jl`](https://github.com/oxinabox/DataDeps.jl) — download-on-first-access with checksum verification; registration lives in code rather than a manifest file (see [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion).
- [`DataToolkit.jl`](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) — the most comparable: a rich, declarative data-management ecosystem with lazy loading and a broad driver set (the better fit for large driver sets and lazily-loaded web resources; it also allows in-config code via its meta `@syntax`, where DataManifest prefers references to external code).
- [`DrWatson.jl`](https://juliadynamics.github.io/DrWatson.jl/dev/) — broader scientific-project organization (simulations, file layout, naming), of which data handling is one part.
- [`RemoteFiles.jl`](https://github.com/helgee/RemoteFiles.jl) — keep a local file in sync with a remote URL.
- Pkg Artifacts (`Artifacts.toml`) — Julia's built-in TOML manifest of content-addressed, hash-pinned data/binary bundles tied to packages.

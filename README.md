<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="datamanifest.toml" height="76">
  </picture>
</p>

# DataManifest.jl

[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)

Keep track of the datasets used in a scientific project. You declare your data
dependencies — URLs, git repositories, checksums, formats — in a `Datasets.toml`
file; `DataManifest.jl` downloads, verifies, extracts and loads them, and caches
your own computed results with the same machinery. It supports data repositories
such as PANGAEA or Zenodo and git hosts such as GitHub. The manifest format is
[shared across languages](https://github.com/perrette/datamanifest.toml) — the
[Python implementation](https://github.com/perrette/datamanifest) reads the same
file, and brings a [full command-line interface](#manage-your-data-from-the-shell)
on top.

`DataManifest.jl` is still actively developed, with breaking changes until
v1.0.0 is reached.

## Installation

```julia
using Pkg
Pkg.add("DataManifest")
```

Bleeding edge:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

## Quick start

In an activated project (`using Pkg; Pkg.activate(...)`):

```julia
using DataManifest

DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")   # resolves under datasets_dir (a machine-global shared store by default)
```

The `add` downloaded the Mauna Loa CO₂ record and wrote one entry to
`Datasets.toml` next to your `Project.toml` — a plain TOML file you can read and
edit by hand, byte-identical to what the sibling Python tool writes:

```toml
[co2]
checksum = "sha256:0058b3788040b5c27b2b5c1dd6d26226b7e4deef85e34c153e64806c37df7c75"
uri = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"
```

**Commit `Datasets.toml`** — it's the recipe (what to fetch and how). The
downloaded data lives outside the repo by default, and the local
`.datamanifest/state.toml` (which records *where* each file landed on this
machine) sits in the git-ignored `.datamanifest/` directory. A collaborator
runs `download_datasets()` to materialize everything.

To be explicit instead of relying on the activated project:

```julia
db = Database("Datasets.toml", "my-data-folder")
DataManifest.add(db, "https://…"; name="…")
path = get_dataset_path(db, "co2")
```

For library code that wants checksummed downloads into a folder it controls —
an OS-appropriate data dir, say — a **file-less database** skips the manifest
entirely: no `Datasets.toml`, no state file, nothing written but the data. The
folder accepts the same `$`-symbols as the storage model, e.g. `$user_data_dir`
or `$user_cache_dir` (`raw"…"` keeps Julia from interpolating the `$`):

```julia
db = Database(datasets_folder=raw"$user_data_dir/mylib", persist=false)
DataManifest.add(db, "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path(db, "co2")   # → ~/.local/share/mylib/gml.noaa.gov/…/co2_annmean_mlo.csv
```

With a loader declared for the dataset (or its format), `load_dataset("co2")`
returns the loaded object directly — see
[per-language bindings](docs/language-bindings.md).

## Produce-or-load caching (`@cached`)

Cache the result of an expensive computation, keyed by its parameters:

```julia
using DataManifest

@cached key=(a -> (; a.grid)) function load_anomaly(; grid::String = "5x5")
    # … expensive computation …
    return result
end

load_anomaly(; grid="5x5")               # computes once, then loads from disk on repeat calls
load_anomaly(; grid="5x5", cached=false) # escape hatch: run the body, no disk I/O
```

Each distinct parameter combination is stored separately under the per-project
cache (`$user_cache_dir/datamanifest/projects/$project/cached` by default),
self-describing and reproducible across tools. Serialization is the
zero-dependency `jls` built-in; register others (`nc`, `jld2`, …) with
`DataManifest.Cache.register_format!`, and pass `version=` to deliberately bust
the cache. Full behaviour — the cache key, artifact layout, `cachetype`
identity: [docs/caching.md](docs/caching.md).

## Manage your data from the shell

DataManifest.jl ships no CLI of its own — it doesn't need one. The manifest is
language-neutral, and the Python implementation's **`datamanifest`** CLI manages
the same file (it auto-detects `Datasets.toml`): everything around the data —
adding, listing, verifying, repairing, syncing — works from the shell, without
touching your Julia code.

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
the use cases and the [CLI reference](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
for every command. The two tools also cooperate at fetch time: a dataset whose
fetcher is written in Python is materialized by delegating to this same CLI
(and the Python tool can delegate to Julia in turn) — see
[cross-language fetch](docs/language-bindings.md#the-ladders).

## One manifest, several languages

A dataset can carry per-language `fetcher`/`loader` bindings under `_LANG` —
`Module:function` references, never inline code. Each implementation runs its
own and preserves the others verbatim, so one manifest serves a mixed
Julia/Python project:

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

A single-language project can skip the `_LANG` ceremony with bare
`fetcher` / `loader` / `shell` fields. Resolution ladders, parameterized
bindings (`{ ref, args, kwargs }`), lazy access to object stores
(`lazy_access`), and cross-language fetch:
[docs/language-bindings.md](docs/language-bindings.md).

## Put data where you want it

Storage is two folders — `datasets_dir` (fetched data) and `datacache_dir`
(`@cached` results) — defaulting to a machine-global shared store and a
per-project cache (spec-v5), with `$`-symbols and per-host overrides for
anything else. Set them in the committed `[_STORAGE]`, or per machine in the
git-ignored `.datamanifest/config.toml` / `~/.config/datamanifest/config.toml`:

```toml
[_STORAGE]
datasets_dir = "datasets"                # repo-local layout, if you prefer it

[_STORAGE._HOST."login*.hpc.edu"]
datasets_dir = "/scratch/$USER/data"     # host-specific override
```

Path expressions, the resolution ladder, the config files, per-dataset
overrides, read pools (reuse data another project already fetched), and the
state file that makes moved data recoverable: [docs/storage.md](docs/storage.md).

## Documentation

- [docs/doc.md](docs/doc.md) — the long-form walkthrough; [docs/api.md](docs/api.md) — the API.
- [docs/language-bindings.md](docs/language-bindings.md) — `_LANG`, ladders, `lazy_access`, migration.
- [docs/storage.md](docs/storage.md) — storage model, read pools, state file, maintenance.
- [docs/caching.md](docs/caching.md) — the `@cached` layer in full.

## Conformance

This release targets the **datamanifest.toml spec tag `spec-v5`**
(<https://github.com/perrette/datamanifest.toml>); a complete annotated example
manifest lives there
([`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)).
Implemented capabilities: `lang-read`, `lang-write`, `shell-fetch`, `storage`,
`binding-args`, `byte-identity`, `cache-produce`, `inspect`, `delegation`; only
`sync` (cross-machine `push`/`pull`) is not yet implemented — use the Python CLI
for that.

## Roadmap

Nothing at this point. After some time of usage and feedbacks, the roadmap will
be updated, and eventually I'll make the v1.0.0 release.

## Related projects

What sets DataManifest.jl apart is the **cross-language manifest**: it is one
member of a multi-language *DataManifest family* built on a shared TOML schema,
so the same `Datasets.toml` is read by sibling tools in other languages via the
`_LANG` namespace — a Julia and a Python project can share one data declaration
without stepping on each other. Configuration stays **declarative**: custom
logic lives in *references to external Julia code* (`Module:function`) rather
than code embedded in the config file. A casual user still writes three lines to
register and fetch a dataset; the rest is there when a project needs it.

**The DataManifest family (one manifest, many languages):**

- [`perrette/datamanifest.toml`](https://github.com/perrette/datamanifest.toml) — the shared TOML schema spec; the common contract every implementation reads.
- [`perrette/datamanifest`](https://github.com/perrette/datamanifest) — the Python implementation, sharing the same `Datasets.toml` via the `_LANG` namespace; also the home of the [CLI](#manage-your-data-from-the-shell).

**Julia alternatives** (single-language). As a rule of thumb: if you only need code-driven download-and-checksum, DataDeps.jl is lighter; if you want a rich declarative data ecosystem, DataToolkit.jl is richer; DataManifest.jl targets multi-dataset, multi-language scientific projects that want the whole dependency declaration — and its derived-data cache — in one shareable file.

- [`DataDeps.jl`](https://github.com/oxinabox/DataDeps.jl) — download-on-first-access with checksum verification; registration lives in code rather than a manifest file (see [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion).
- [`DataToolkit.jl`](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) — the most comparable: a rich, declarative data-management ecosystem with lazy loading and a broad driver set (the better fit for large driver sets and lazily-loaded web resources; it also allows in-config code via its meta `@syntax`, where DataManifest prefers refs to external code).
- [`DrWatson.jl`](https://juliadynamics.github.io/DrWatson.jl/dev/) — broader scientific-project organization (simulations, file layout, naming), of which data handling is one part.
- [`RemoteFiles.jl`](https://github.com/helgee/RemoteFiles.jl) — keep a local file in sync with a remote URL.
- Pkg Artifacts (`Artifacts.toml`) — Julia's built-in TOML manifest of content-addressed, hash-pinned data/binary bundles tied to packages.

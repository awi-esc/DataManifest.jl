[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)

# DataManifest.jl

Keep track of datasets used in a project.

Provide a simple and straightforward way to keep track of datasets downloaded from the web.

Currently DataManifest supports download from a set of URLs suited for repositories like PANGEA or ZENODO, as well as git-based repositories such as github. Support for more remote repositories will be added along the way as necessary.

It provides declarative functions to register and download datasets, as well as a way to write to and read from an equivalent (and optional) `toml` config file.

`DataManifest.jl` is still actively developped, with breaking changes until v1.0.0 is reached (see [roadmap](#roadmap) below).

## How to install?

This package can be installed as:
```julia
using Pkg
Pkg.add("DataManifest")
```
and the bleeding edge can be installed directly via:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

## Usage

Let's assume you work in an activated package (`using Pkg; Pkg.activate(...)`) with a `Project.toml`.
The simplest way to add a dataset is as follow:

```julia
using DataManifest;
DataManifest.add("https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"; extract=true, name="jesstierney/lgmDA")
```
will generate `Datasets.toml` next to your `Project.toml` with the content

```toml
["jesstierney/lgmDA"]
uri = "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
sha256 = "da5f85235baf7f858f1b52ed73405f5d4ed28a8f6da92e16070f86b724d8bb25"
extract = true
```
and download and extract the corresponding dataset, which can be accessed via
```julia
get_dataset_path("jesstierney/lgmDA")  # defaults to ~/.cache/Datasets/...
```

If you're not working in an activated environment, or want to be more explicit for your readers, you can specify the paths and simply prefix every command with the loaded database:
```julia
db = Database("datasets.toml", "my-data-folder")
DataManifest.add(db, ...)
path = get_datasets_path(db, ...)
```

or even work with in-memory database (the toml, not the data), if you don't mind about checksums etc
```julia
db = Database(datasets_folder="my-data-folder", persist=false)
add(db, ...) # will simply download things and update db without writing any toml to disk
```

## Documentation

See the [full documentation](/docs/doc.md) and the [API](/docs/api.md).

## Schema v1 and the `_LANG` namespace

DataManifest now supports **schema v1** (`_META.schema = 1`), which introduces a language-namespaced binding model. Under v1, custom fetch and load logic is expressed as `module:function` references stored in a `_LANG.julia` subtable rather than as inline Julia code.

### Declaring bindings in a v1 manifest

```toml
[_META]
schema = 1

[_LANG.julia.loaders]
nc = "MyProject:load_netcdf"          # format-level default loader

[my_dataset._LANG.julia]
fetcher = "MyFetchers:fetch_my_data"  # called instead of built-in URI download
loader  = "MyLoaders:load_my_data"    # called instead of format default
```

Bindings are resolved at runtime: `"Module:function"` causes `using Module` followed by `getfield(Module, :function)` — no `eval`, no `include_string`.

### Resolution ladders

**Load** (in order): own `_LANG.julia.loader` → manifest `[_LANG.julia.loaders][format]` → built-in format default → error. Never spawns a subprocess.

**Fetch** (in order): own `_LANG.julia.fetcher` → `_LANG.shell.fetcher` (shell template) → `uri`/`uris` → error. Delegation to peer CLIs is not yet implemented.

### v0/v1 split for inline code

Legacy manifests (no `_META.schema`) continue to work: inline `julia=`/`loader=` fields and `[_LOADERS]` are still read and executed. Under v1 (`schema = 1`) only `module:function` refs are used for bindings; the inline execution path is skipped.

### Multi-language round-trip

Foreign `_LANG.<other>` subtrees (e.g. `[bar._LANG.python]`) and unknown `_*` top-level tables are carried through verbatim on every read→write cycle. Only the Julia subtree is regenerated from the model; all other language namespaces are never modified.

### Migrating a v0 manifest

```julia
DataManifest.migrate("Datasets.toml")
```

Moves ref-shaped `julia=`/`loader=` fields and `[_LOADERS]` ref entries into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]` and sets `_META.schema = 1`. Inline code that cannot become a ref is preserved verbatim with a log note. The call is idempotent: already-v1 files are left unchanged.

## Storage model

As of v0.18.0 (spec-v3), DataManifest uses a portable **`$`-folder-variable storage
model**: a folder names a **bare root**, and the layer composes the rest of the path
(`datasets/` for fetched data, `cached/` for produced artifacts) plus an optional **scope**:

```toml
[_META]
schema = 1

[_STORAGE]
default = "$data"                # project-wide default selector (defaults to $data)
scratch = "$TMPDIR"              # user-defined folder variable (a bare root) -> $scratch

[_STORAGE._HOST."login*.hpc.edu"]
scratch = "/scratch/$USER"       # same variable, host-specific resolution

[_STORAGE._SCOPE]
# datasets = "shared-pool"        # share fetched downloads within a group (default: shared)

[my_dataset]
store = "$cache"                 # put this dataset under the cache folder's datasets/ tree
uri   = "https://example.com/ds.nc"

[big]
store = "$cache/derived"         # sub-path: keyed under <cache>/derived/datasets/<key>
uri   = "https://example.com/big.nc"
```

A **folder** is referenced as a `$`-variable resolving to a **bare top-level root**; the
consuming layer adds `datasets/[<scope>/]` (fetch) or `cached/[<scope>/]` (produce) on top:

| Folder   | Bare root (Linux)                                   | Fetched dataset path           |
|----------|-----------------------------------------------------|--------------------------------|
| `$data`  | `$DATAMANIFEST_DIR` or `$XDG_DATA_HOME/datamanifest` | `<root>/datasets/<key>`        |
| `$cache` | `$DATAMANIFEST_DIR` or `$XDG_CACHE_HOME/datamanifest`| `<root>/datasets/<key>`        |
| `$repo`  | `<project_root>`                                    | `<root>/datasets/<key>`        |

Any other `[_STORAGE]` key defines a **user folder** (`scratch = "…"` → `$scratch`).
A dataset's `store` (and `[_STORAGE].default`) is a `$`-folder **selector**, optionally with
a sub-path (`$cache/derived`); `[_STORAGE]` values and `local_path` are **path expressions**
interpolating `$`-folder variables, `$USER`/env, and `~`. The `datasets` scope is empty by
default (downloads are shared across projects); produced artifacts default to a
project-isolated `cached` scope.

> **Breaking change in v0.18.0 (spec-v3)**: folders are now bare roots and the layer applies
> a lowercase `datasets/` prefix, so the fetched path moved `…/datamanifest/Datasets/<key>`
> → `…/datamanifest/datasets/<key>`. Existing v0.17.0 downloads still resolve (read-only
> probe); set `DATAMANIFEST_DIR` to put everything under one tree. `_PROFILE` is shelved
> (preserved, not resolved) — use the auto-matched `_HOST`.

Every folder variable resolves through one ladder:
`DATAMANIFEST_<NAME>_DIR` env-var → first matching `_HOST.<glob>` → `[_STORAGE]` base →
built-in default. Prefixes/scopes resolve through `DATAMANIFEST_PREFIX_<KIND>` /
`DATAMANIFEST_SCOPE_<KIND>` → `[_STORAGE._PREFIX | _SCOPE].<kind>` → default.

## Produce-or-load caching (`@cached`)

Beyond *fetching* declared datasets, DataManifest can *produce-or-load* — cache the result
of a project function on disk, keyed by its parameters (spec-v3 `cache-produce`):

```julia
using DataManifest

@cached cachetype="esm_anomaly" ext="jls" key=(a -> (; a.grid, a.skip_models)) function load_anomaly(;
        grid::String = "5x5",
        skip_models::Vector{String} = ["CESM.*", "FGOALS.*"],
        _verbose::Bool = false)          # `_`-prefixed = runtime knob, excluded from the hash
    # … expensive computation …
    return result
end

load_anomaly(; grid="5x5")               # computes once, then loads from disk on repeat calls
load_anomaly(; grid="5x5", cached=false) # escape hatch: run the body, no disk I/O
```

The cache key is the SHA-256 of the **canonical JSON** of the hash-affecting keyword
parameters (cross-tool reproducible). Produced datasets are **keyword-only**; hash inputs
must be strings/integers/booleans/arrays/objects — floats and nulls raise (pass a float as a
string). Each artifact is self-describing — `config.toml` (the re-hashable key table) and
`metadata.toml` (provenance) sit alongside it at
`<$cache>/cached/<project>/<cachetype>/[<version>/]<hash>/`. `jls` (stdlib `Serialization`)
is the built-in format; register others (`nc`, `jld2`, …) with
`DataManifest.Cache.register_format!`.

## Parameterized bindings

Fetcher and loader refs can carry `args`/`kwargs` for more flexible dispatch:

```toml
[my_dataset._LANG.julia]
fetcher = { ref = "MyFetchers:fetch", args = ["$download_path"], kwargs = { format = "nc" } }
loader  = { ref = "MyLoaders:load",  args = ["$path"],           kwargs = { grid = "5x5" } }
```

At call time, `$var` placeholders in string values are substituted with the dataset's context variables (`$download_path` / `$path`, `$key`, `$uri`, etc.) and the function is called as `ref(args...; kwargs...)`. Bare-string bindings (`fetcher = "Mod:fn"`) are unaffected.

## Conformance

This release targets the **datamanifest.toml spec tag `spec-v1.1`** (source of truth: <https://github.com/perrette/datamanifest.toml>).

Implemented capabilities: **`lang-read`**, **`lang-write`**, **`shell-fetch`**, **`storage`**, **`binding-args`**, **`byte-identity`**.

The test suite downloads the spec's tagged tarball, verifies every fixture file against a pinned per-file sha256 map (`test/conformance_pin.toml`), and runs only the fixtures whose capability set is a subset of the above. Fixtures requiring unimplemented capabilities (e.g. delegation) are skipped with a logged reason.

## Roadmap

Nothing at this point. After some time of usage and feedbacks, the roadmap will be updated, and eventually I'll make the v1.0.0 release.

## Why DataManifest.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757), [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl) and [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. See [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion of `DataDeps.jl`.  **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **DataManifest.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. DataManifest.jl stays focused on download and on-disk management and adds a minimal, user-defined loader layer; for richer loader ecosystems and lazy loading of web resources, DataToolKit is the better fit.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). Over time though, I've also come to implement a simple, user-defined loader functionality, so perhaps the distinction is starting to blurr. Nonetheless, while examples provided in DataToolKit to clean-up datasets use lots of code inside the config file (via the meta `@syntax`), in DataManifest the recommended approach is to simply add references to external julia code so `DataManifest` knows what to use to load the various datasets. Also in my brief DataToolKit trial, I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **DataManifest.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.

## Related projects

The defining feature of `DataManifest.jl` is that it is one member of a multi-language *DataManifest family* built on a shared TOML schema: the same `datasets.toml` can be consumed by sibling implementations in different languages (via the `_LANG` namespace), so a Julia project and, say, a Python project can share a single data declaration without stepping on each other. None of the Julia-only tools below target this.

**The DataManifest family (one manifest, many languages):**

- [`perrette/datamanifest.toml`](https://github.com/perrette/datamanifest.toml) — the shared TOML schema spec; the common contract every implementation reads.
- [`perrette/datamanifest`](https://github.com/perrette/datamanifest) — the Python implementation, sharing the same `datasets.toml` via the `_LANG` namespace.

**Julia alternatives** (single-language; see [Why DataManifest.jl?](#why-datamanifestjl-) above for the detailed comparison):

- [`DataDeps.jl`](https://github.com/oxinabox/DataDeps.jl) — download-on-first-access with checksum verification; registration lives in code rather than a manifest file.
- [`DataToolkit.jl`](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) — a rich, declarative data-management ecosystem with lazy loading and a broad driver set.
- [`DrWatson.jl`](https://juliadynamics.github.io/DrWatson.jl/dev/) — broader scientific-project organization (simulations, file layout), of which data handling is one part.
- [`RemoteFiles.jl`](https://github.com/helgee/RemoteFiles.jl) — keep a local file in sync with a remote URL.
- Pkg Artifacts (`Artifacts.toml`) — Julia's built-in TOML manifest of content-addressed, hash-pinned data/binary bundles tied to packages.

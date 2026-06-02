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

As of v0.16.0, DataManifest supports a portable **storage model** that keeps dataset paths consistent across languages:

```toml
[_META]
schema = 1

[_STORAGE]
data = "/data/shared"            # override the data-store root

[my_dataset]
store = "cache"                  # put this dataset in the cache store
uri   = "https://example.com/ds.nc"
```

Each dataset can declare `store = "data"` (default), `"cache"`, `"repo"` (inside the project), or `"mount"` (parsed verbatim, not yet mounted). Default roots follow Python's `platformdirs`:

| Store  | Linux default                              |
|--------|--------------------------------------------|
| `data` | `$XDG_DATA_HOME/datamanifest/Datasets`     |
| `cache`| `$XDG_CACHE_HOME/datamanifest/Datasets`    |
| `repo` | `<project_root>/datasets`                  |

> **Behavior change in v0.16.0**: the `data` store default moved from
> `$XDG_CACHE_HOME/Datasets` to `$XDG_DATA_HOME/datamanifest/Datasets`.
> Set `DATAMANIFEST_DATA_DIR` to your old path to keep resolving existing files.

Per-store root precedence: `DATAMANIFEST_<STORE>_DIR` env-var →
`_PROFILE.<name>` (when `DATAMANIFEST_PROFILE` set) → first matching
`_HOST.<glob>` → `[_STORAGE]` base → default. `~` and `$VAR` expanded.

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

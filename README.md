<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="datamanifest.toml" height="76">
  </picture>
</p>

# DataManifest.jl

[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)

Keep track of datasets used in a project.

`DataManifest.jl` provides a simple way to declare data dependencies — URLs, git repositories, checksums, formats — in a `Datasets.toml` file, and handles download, verification, extraction, and loading. It can also cache your own computed results (versioned), reusing the same infrastructure.

It supports downloads from data repositories such as PANGAEA or Zenodo and from git-based hosts such as GitHub; support for more remotes is added as needed. DataManifest.jl is the Julia implementation of a [multi-language specification](https://github.com/perrette/datamanifest.toml): the same `Datasets.toml` can be shared with sibling tools in other languages (e.g. the [Python implementation](https://github.com/perrette/datamanifest)) via the `_LANG` namespace.

`DataManifest.jl` is still actively developed, with breaking changes until v1.0.0 is reached (see [roadmap](#roadmap) below).

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
get_dataset_path("jesstierney/lgmDA")  # resolves under the $data folder, e.g. ~/.local/share/datamanifest/datasets/...
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

## Per-language bindings (`_LANG`)

Custom fetch and load logic lives in a dedicated `_LANG` namespace, so a single manifest can serve multiple language implementations without conflicts. Bindings are `module:function` references — never inline code (the snippets below are drawn from the spec's [`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)):

```toml
[_META]
schema = 1

# Project-wide default loaders, per language: format -> binding.
[_LANG.julia.loaders]
csv = "CSV:read"
nc  = "NCDatasets:Dataset"

# A per-dataset loader override (overrides the nc format default for this dataset only).
[ocean_temp._LANG.julia]
loader = "MyClimate:load_argo"

# A dataset with no public URI: produced by a fetcher. The own-language fetcher runs
# in-process; the shell fetcher is a cheap cross-language fallback that writes $download_path.
[model_output._LANG.julia]
fetcher = "MyClimate:build_model_output"
[model_output._LANG.shell]
fetcher = "make model_output OUTPUT=$download_path"
```

A `"Module:function"` ref is resolved at runtime by `using Module` followed by `getfield(Module, :function)` — no `eval`, no `include_string`.

**Fetch ladder** (per dataset, in order): own `_LANG.julia.fetcher` (or the bare `fetcher`) → the dataset's `shell` command → **cross-language fetch (rung 3)** → `uri`/`uris` → error. Rung 3 is the rare case where a dataset's bytes can be produced only by a foreign-language fetcher (e.g. `[<ds>._LANG.python].fetcher`): DataManifest.jl delegates to the Python `datamanifest` CLI when it is on `PATH` (`datamanifest download <name>`), which materializes the result in the shared store; it falls through to `uri` when the peer is absent, disabled (`delegate = false`), or fails.

**Load ladder** (per dataset, in order): own `_LANG.julia.loader` (or the bare `loader`) → manifest `[_LANG.julia.loaders][format]` (or `[_LOADERS][format]`) → built-in format default → error. Never spawns a subprocess.

**Bindings are string or table** at every site (spec-v3.3) — a bare `module:function` string, or a `{ ref, args, kwargs }` table — including the project-wide `[_LANG.julia.loaders]` map, so a format default can be parameterized exactly like a per-dataset loader.

**Language-implicit (bare) bindings** (spec-v3.4): for a single-language project you may skip the `_LANG.julia` wrapper and write a bare `fetcher`/`loader` directly on the dataset (and a top-level `[_LOADERS]` format map) — read as the running tool's **own-language** binding. An explicit `_LANG.julia` binding takes precedence. A bare binding is *present* for Julia, so it is treated like an explicit one — **fail loud** (spec-v3.6): a resolution failure errors and a runtime error propagates, never a silent fall-through; the ladder only skips bindings *absent* for Julia (another language's `_LANG.<other>`). The **`shell`** field is the language-*agnostic* sibling (spec-v3.5) — the same command for every tool. Foreign `_LANG.<other>` subtrees, bare bindings, `[_LOADERS]`, and unknown `_*` tables all round-trip verbatim; only the Julia `_LANG` subtree is regenerated from the model.

### Parameterized bindings

A binding's **table form** carries `args`/`kwargs`, reusing one function across datasets that differ only in arguments:

```toml
[esm_5x5._LANG.julia.loader]
ref    = "MyClimate:load_esm"
args   = ["$path"]
kwargs = { grid = "5x5", skip_models = ["CESM.*"] }
```

At call time, `$var` placeholders in string values are substituted with the dataset's context variables (`$download_path` / `$path`, `$key`, `$uri`, `$version`, `$doi`, `$format`, `$branch`, `$project_root`) and the function is called as `ref(args...; kwargs...)`. A ref-only binding — the bare string `"Mod:fn"`, equivalently `{ ref = "Mod:fn" }` — keeps the conventional call and is written back as the string.

### Migration

```julia
DataManifest.migrate("Datasets.toml")
```

Legacy manifests (no `_META` header, inline `julia=`/`loader=` fields, `[_LOADERS]`) are still read and executed. `migrate` moves ref-shaped fields into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]` and adds the `[_META]` header; inline code that cannot become a ref is preserved verbatim with a log note. The call is idempotent.

## Storage model

DataManifest uses a portable **`$`-folder-variable storage model**: a folder names a **bare
root**, and the layer composes the rest of the path (`datasets/` for fetched data, `cached/`
for produced artifacts) plus an optional **scope**:

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

> **Behavior change from earlier releases.** Folders are now bare roots and the layer applies
> a lowercase `datasets/` prefix, so the fetched path moved `…/datamanifest/Datasets/<key>`
> → `…/datamanifest/datasets/<key>`. Existing downloads still resolve (read-only probe); set
> `DATAMANIFEST_DIR` to put everything under one tree. `_PROFILE` is accepted and
> round-tripped but not applied during resolution — use the auto-matched `_HOST`.

Every folder variable resolves through one ladder:
`DATAMANIFEST_<NAME>_DIR` env-var → first matching `_HOST.<glob>` → `[_STORAGE]` base →
built-in default. Prefixes/scopes resolve through `DATAMANIFEST_PREFIX_<KIND>` /
`DATAMANIFEST_SCOPE_<KIND>` → `[_STORAGE._PREFIX | _SCOPE].<kind>` → default.

## Produce-or-load caching (`@cached`)

Beyond *fetching* declared datasets, DataManifest can *produce-or-load* — cache the result
of a project function on disk, keyed by its parameters:

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
parameters (cross-tool reproducible). Produced datasets are **keyword-only**; hash inputs are
strings/integers/booleans/**finite floats**/arrays/objects of those — finite floats use the
normative Python `json.dumps` form (`1.0`→`1.0`), while `NaN`/`±Inf` and nulls raise. Each artifact is self-describing — `config.toml` (the re-hashable key table) and
`metadata.toml` (provenance) sit alongside it at
`<$cache>/cached/<project>/<cachetype>/[<version>/]<hash>/`. `jls` (stdlib `Serialization`)
is the built-in format; register others (`nc`, `jld2`, …) with
`DataManifest.Cache.register_format!`.

### The `cached.toml` index and store maintenance (`inspect`)

On a produce, the artifact is registered in the project's **`cached.toml`** — the
produced-dataset registry (the `Manifest.toml` analogue, sibling to `datasets.toml`) that
lists each produced dataset by its portable `cachetype` + `hash` key, never an absolute path.
Read or build one with `CachedIndex` / `read_index` / `register!` / `write_index`.

`inspect_store(db)` enumerates produced artifacts **and** present fetched datasets as one
list of `CacheObject`s (`kind`, `key`/`hash`, `scope`, `format`, `size`, `created`,
`last_access`, `referenced`), resolving `referenced` from `cached.toml`. Filter the list and
act with `delete_object` / `move_object` — there is **no automatic garbage collector**;
deletion is always an explicit selection, and only produced (`cached`) artifacts are eligible.
A produced artifact's **last-access** time (`last_access`) is read purely from the filesystem
at inspect time — never written on read — so it is coarse and may track mtime on
`noatime`/`relatime` mounts; `created` is the always-available age signal.

```julia
db = read_dataset("datasets.toml")
for o in inspect_store(db)
    o.kind == "cached" && o.referenced == false && delete_object(o)   # prune orphaned artifacts
end
```

## Conformance

This release targets the **datamanifest.toml spec tag `spec-v3.6`** (source of truth: <https://github.com/perrette/datamanifest.toml>). A complete, annotated example manifest lives there: [`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml).

Implemented capabilities: **`lang-read`**, **`lang-write`**, **`shell-fetch`**, **`storage`**, **`binding-args`**, **`byte-identity`**, **`cache-produce`**, **`inspect`**, **`delegation`**. Only **`sync`** (cross-machine `push`/`pull`) is not yet implemented.

The test suite downloads the spec's tagged tarball, verifies every fixture file against a pinned per-file sha256 map (`test/conformance_pin.toml`), and runs only the fixtures whose capability set is a subset of the above. Fixtures requiring unimplemented capabilities (e.g. `sync`) are skipped with a logged reason.

## Roadmap

Nothing at this point. After some time of usage and feedbacks, the roadmap will be updated, and eventually I'll make the v1.0.0 release.

## Related projects

DataManifest.jl started as a deliberately minimal, KISS alternative — one `Datasets.toml` declaring URLs and checksums, plus download. It is no longer quite that tiny: it has grown a focused, opt-in feature set — a user-defined loader layer, a portable `$`-folder storage model (host overrides, scopes), produce-or-load caching (`@cached`) with a `cached.toml` index and store maintenance, and parameterized bindings — while keeping configuration **declarative**: custom logic lives in *references to external Julia code* (`Module:function`) rather than code embedded in the config file. A casual user still writes three lines to register and fetch a dataset; the rest is there when a project needs it.

What sets it apart, though, is not its feature set but the **cross-language manifest**: DataManifest.jl is one member of a multi-language *DataManifest family* built on a shared TOML schema, so the same `Datasets.toml` is read by sibling tools in other languages via the `_LANG` namespace — a Julia and a Python project can share one data declaration without stepping on each other. None of the Julia-only tools below target this.

**The DataManifest family (one manifest, many languages):**

- [`perrette/datamanifest.toml`](https://github.com/perrette/datamanifest.toml) — the shared TOML schema spec; the common contract every implementation reads.
- [`perrette/datamanifest`](https://github.com/perrette/datamanifest) — the Python implementation, sharing the same `datasets.toml` via the `_LANG` namespace.

**Julia alternatives** (single-language). As a rule of thumb: if you only need code-driven download-and-checksum, DataDeps.jl is lighter; if you want a rich declarative data ecosystem, DataToolkit.jl is richer; DataManifest.jl targets multi-dataset, multi-language scientific projects that want the whole dependency declaration — and its derived-data cache — in one shareable file.

- [`DataDeps.jl`](https://github.com/oxinabox/DataDeps.jl) — download-on-first-access with checksum verification; registration lives in code rather than a manifest file (see [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion).
- [`DataToolkit.jl`](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) — the most comparable: a rich, declarative data-management ecosystem with lazy loading and a broad driver set (the better fit for large driver sets and lazily-loaded web resources; it also allows in-config code via its meta `@syntax`, where DataManifest prefers refs to external code).
- [`DrWatson.jl`](https://juliadynamics.github.io/DrWatson.jl/dev/) — broader scientific-project organization (simulations, file layout, naming), of which data handling is one part.
- [`RemoteFiles.jl`](https://github.com/helgee/RemoteFiles.jl) — keep a local file in sync with a remote URL.
- Pkg Artifacts (`Artifacts.toml`) — Julia's built-in TOML manifest of content-addressed, hash-pinned data/binary bundles tied to packages.

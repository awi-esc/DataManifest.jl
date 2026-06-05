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
get_dataset_path("jesstierney/lgmDA")  # resolves under datasets_dir, by default ./datasets/<key>
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
# in-process; the bare, language-agnostic `shell` command is the same for every tool
# and writes to $download_path.
[model_output]
format = "nc"
shell  = "make model_output OUTPUT=$download_path"

[model_output._LANG.julia]
fetcher = "MyClimate:build_model_output"

# Single-language shorthand: a bare `loader` (no `_LANG` wrapper) is read as Julia's own.
[sea_ice]
uri    = "https://example.com/sea_ice.nc"
format = "nc"
loader = "MyClimate:load_sea_ice"
```

A `"Module:function"` ref is resolved at runtime by `using Module` followed by `getfield(Module, :function)` — no `eval`, no `include_string`.

**Fetch ladder** (per dataset, in order): own `_LANG.julia.fetcher` (or the bare `fetcher`) → the dataset's `shell` command → **cross-language fetch (rung 3)** → `uri`/`uris` → error. Rung 3 is the rare case where a dataset's bytes can be produced only by a foreign-language fetcher (e.g. `[<ds>._LANG.python].fetcher`): DataManifest.jl delegates to the Python `datamanifest` CLI when it is on `PATH` (`datamanifest download <name>`), which materializes the result in the shared store; it falls through to `uri` when the peer is absent, disabled (`delegate = false`), or fails.

**Load ladder** (per dataset, in order): own `_LANG.julia.loader` (or the bare `loader`) → manifest `[_LANG.julia.loaders][format]` (or `[_LOADERS][format]`) → built-in format default → error. Never spawns a subprocess.

**Access mode — `lazy_access`** (spec-v4.3). Set `lazy_access = true` to open the `uri` *in place* via a loader instead of materializing a local copy — no download, no checksum, no state-file record, and maintenance leaves it alone. It **requires a loader** (a bare `lazy_access` with no loader errors): the loader is what knows how to open the `uri` where it lives, so this is the natural way to read **object-store** URIs (`s3://`, `gs://`, `gcs://`, `az://`, `abfs://`, `abfss://`, `adl://`, `gdrive://`) with a scheme-aware loader. *Downloading* an object-store URI is not natively supported (no built-in backend) — it errors clearly, pointing you to `lazy_access` or delegation, rather than failing silently. `lazy_access` is distinct from `skip_download` (a *management* mode: the documented local file is used as-is). Identifier resolution is also **exact-or-error**: a name/alias/`doi` matching more than one dataset is a fail-loud error, never a silent first-match.

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

DataManifest storage reduces to **two folder fields**, both **local by default**, with nothing
derived — the folder you set IS the location:

```toml
[_META]
schema = 1

[_STORAGE]
datasets_dir  = "datasets"       # fetched datasets  -> <datasets_dir>/<key>     (default ./datasets/)
datacache_dir = "cached"         # produced cache    -> <datacache_dir>/<cachetype>/[<version>/]<hash>/  (default ./cached/)
scratch       = "$TMPDIR"        # user-defined symbol -> $scratch

[_STORAGE._HOST."login*.hpc.edu"]
scratch = "/scratch/$USER"       # same symbol, host-specific resolution

[my_dataset]
uri = "https://example.com/ds.nc"
# default storage_path is "$datasets_dir/$key"

[in_repo]
uri          = "https://example.com/manual.nc"
storage_path = "data/manual.nc"  # exact path, no $key -> user-managed, never touched by maintenance
```

A **relative** folder is relative to the **project root** (`$repo`); an absolute path, a `~`
path, or a `$symbol`-rooted path is used as written. There is **no scope, no prefix, no
appname, no derived name, and no `store` selector** — to centralize or share data, point a
folder at a shared location (e.g. `datasets_dir = "$user_data_dir/<name>"`) in one explicit
edit; there is no automatic scoping.

**`$`-symbols** interpolate in any path. The predefined ones are **bare** (no `datamanifest`
app segment): `$user_data_dir` (= `platformdirs.user_data_dir()`, e.g. `~/.local/share`),
`$user_cache_dir` (`~/.cache`), and `$repo` (the project root); plus `$USER`/env vars and `~`.
Any other bare `[_STORAGE]` key is a **user-defined symbol** (`scratch = "…"` → `$scratch`),
and can be made host-specific via `[_STORAGE._HOST."<glob>"]`. Every symbol and field resolves
through one ladder:

> `DATAMANIFEST_<NAME>` env-var → `[_STORAGE._HOST.<glob>].<name>` →
> base `[_STORAGE].<name>` → the predefined default.

**Per-dataset `storage_path`.** A dataset's `storage_path` is a path expression (default
`$datasets_dir/$key`) that **replaces both the old `store` selector and `local_path`**:

- containing `$key` ⇒ a **tool-managed** keyed location;
- an exact path **without** `$key` ⇒ **user-managed**, used verbatim, and never touched by
  store maintenance.

There are exactly **two env overrides**, `DATAMANIFEST_DATASETS_DIR` and
`DATAMANIFEST_DATACACHE_DIR` (user symbols override as `DATAMANIFEST_<NAME>`).

> **Sharing fetched data across projects.** Set `datasets_dir = "$user_data_dir/<name>"` (one
> explicit edit). `_PROFILE` is accepted and round-tripped but not applied during resolution —
> use the auto-matched `_HOST`.

**Read pools** (`datasets_pools` / `datacache_pools`) — *reuse, don't re-fetch.* A read pool is
an extra **read-only** location probed for an already-present object before downloading (or
recomputing), so a dataset another project already fetched — or a `@cached` result it already
produced — is reused **in place** rather than re-obtained. A fetch probes the pools after the
recorded/derived location and before downloading; on a hit it verifies the declared `sha256`
(a mismatch is skipped), records the location in the state file, and returns it — the pool is
never written to, and new downloads still land in `datasets_dir` (the gold standard).

```toml
[_STORAGE]
datasets_pools  = ["$user_data_dir/shared/datasets", "~/.cache/Datasets"]  # list of read-only dirs
# datacache_pools = ["$user_data_dir/shared/cached"]                       # same, for @cached artifacts
```

`datasets_pools` is host-composable (`_HOST`) and env-overridable (`DATAMANIFEST_DATASETS_POOLS`,
`pathsep`-separated); **undefined** falls back to the well-known defaults
(`$user_data_dir/datamanifest/datasets`, `~/.cache/Datasets`), and an explicit **empty** list
disables it. `datacache_pools` is **opt-in** (undefined ⇒ none). *(Python-parity feature, ahead
of the spec.)*

## Produce-or-load caching (`@cached`)

Beyond *fetching* declared datasets, DataManifest can *produce-or-load* — cache the result
of a project function on disk, keyed by its parameters:

```julia
using DataManifest

@cached key=(a -> (; a.grid, a.skip_models)) function load_anomaly(;
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
`metadata.toml` (provenance) sit alongside it under **`datacache_dir`** at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/` (default `./cached/`). `jls` (stdlib
`Serialization`) is the built-in zero-dependency format; register others (`nc`, `jld2`, …)
with `DataManifest.Cache.register_format!`. (The spec RECOMMENDS `jld2` as the Julia
per-language default; shipping `jls` as the built-in self-saver is a documented,
spec-permitted deviation.)

**`cachetype` is optional**: when omitted it defaults to the producing function's canonical
*importable* name — `Module.func` — so it coincides with the recipe `ref`. Pass an explicit
`cachetype=` to override it, and `version=` to deliberately bust the cache. A function with
**no stable importable identity** (script / REPL / `eval` / notebook) must be given an
explicit `cachetype`. (The macro lost its old `store=`/`scope=` options; `cache_dir=` — a
verbatim experiment folder that bypasses `datacache_dir` entirely — and `version=` remain.)

### The state file (`.datamanifest-state.toml`) and store maintenance (`inspect`)

`datasets.toml` is the committed **spec** — *what* to track and *how* to obtain it. *Where*
each object actually landed on this machine is recorded separately in a sibling, **git-ignored**
**`.datamanifest-state.toml`** — the *state file* (regenerable local state, schema 5). One
inventory covers **both** fetched datasets and produced artifacts, under two namespaces. Read
or build one with `CachedIndex` / `read_index` / `register!` / `register_dataset!` /
`write_index`.

```toml
[_META]
schema = 5

# produced artifacts: cachetype[@version] → instances{hash → artifact dir}
[datacache."lgmpre.data.load_20c@v3"]
ref    = "lgmpre.data:load_20c"   # the producing module:function (refreshed across a refactor)
format = "nc"
  [datacache."lgmpre.data.load_20c@v3".instances]
  "83425a30…" = "cached/lgmpre.data.load_20c/v3/83425a30…"   # the full artifact directory

# fetched datasets: storage key → resolved location (+ actual checksum)
[datasets."example.com/foo.nc"]
storage_path = "datasets/example.com/foo.nc"
sha256       = "abc123…"
```

The `datacache` namespace keys each recipe by `(cachetype, version)` (`@` is the reserved
version separator) and maps each variation's parameter `hash` to the **artifact directory** it
was written to — the **params themselves live in each artifact's `config.toml`**, not here.
The `datasets` namespace records each fetched dataset's resolved `storage_path` and **actual**
`sha256`. Registering **accumulates**. The legacy `cached.toml` filename and schema 1–4 forms
are still read and migrated forward on the next write.

**Read-first resolution:** resolving where a fetched dataset lives consults the recorded
`storage_path` first — if those bytes are present, a *moved* dataset is found where it really
lives, ahead of the derived `$datasets_dir/$key` rule (a re-download still writes to the
derived directive location). A successful fetch records the resolved location + actual sha256;
a **cache hit self-heals** the inventory (registers a missing variation, refreshes a drifted
recipe `ref`), best-effort and off the hot path — so a deleted state file repopulates as
objects are accessed. The on-disk `config.toml` stays the cache-validity authority;
`metadata.toml` provenance stays write-if-absent (its `[origin].state_file` back-pointer names
the inventory).

`inspect_store(db)` enumerates produced artifacts **and** present fetched datasets as one
list of `CacheObject`s (`kind`, `key`/`hash`, `format`, `size`, `created`,
`last_access`, `referenced`), resolving `referenced` from the state file on the
`(cachetype, version, hash)` key. Filter the list and act with `delete_object` /
`move_object` — there is **no automatic garbage collector**; deletion is always an explicit
selection, and only produced (`cached`) artifacts are eligible.
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

This release targets the **datamanifest.toml spec tag `spec-v4.1`** (source of truth: <https://github.com/perrette/datamanifest.toml>). A complete, annotated example manifest lives there: [`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml).

Implemented capabilities: **`lang-read`**, **`lang-write`**, **`shell-fetch`**, **`storage`**, **`binding-args`**, **`byte-identity`**, **`cache-produce`**, **`inspect`**, **`delegation`**. Only **`sync`** (cross-machine `push`/`pull`) is not yet implemented.

The test suite downloads the spec's tagged tarball, verifies every fixture file against a pinned per-file sha256 map (`test/conformance_pin.toml`), and runs only the fixtures whose capability set is a subset of the above. Fixtures requiring unimplemented capabilities (e.g. `sync`) are skipped with a logged reason.

## Roadmap

Nothing at this point. After some time of usage and feedbacks, the roadmap will be updated, and eventually I'll make the v1.0.0 release.

## Related projects

DataManifest.jl started as a deliberately minimal, KISS alternative — one `Datasets.toml` declaring URLs and checksums, plus download. It is no longer quite that tiny: it has grown a focused, opt-in feature set — a user-defined loader layer, a portable two-folder `$`-symbol storage model (local by default, with host overrides), produce-or-load caching (`@cached`) with a git-ignored state-file inventory and store maintenance, and parameterized bindings — while keeping configuration **declarative**: custom logic lives in *references to external Julia code* (`Module:function`) rather than code embedded in the config file. A casual user still writes three lines to register and fetch a dataset; the rest is there when a project needs it.

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

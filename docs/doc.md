# Documentation

This is the main user guide. It assumes you have skimmed the [introduction](index.md).

A few terms used throughout:

- A **manifest** is a TOML file, usually named `Datasets.toml`, that declares the
  datasets a project uses: where each one comes from, how to verify it, and
  optionally how to load it into Julia. Each top-level TOML table is one
  **dataset entry**; the table name is how you refer to the dataset from code.
- A **checksum** is a digest of a dataset's content (SHA-256 by default), used to
  detect corruption or upstream changes.
- A **loader** is a function that turns a file path into a Julia object (a
  `DataFrame`, a NetCDF handle, …). A **fetcher** is custom code that downloads a
  dataset when the built-in download does not fit.

Contents:

1. **Everyday usage** — reading a manifest, downloading, getting paths, loading,
   registering datasets from code.
2. **Configuration** — where data is stored, maintaining the manifest file,
   checksum basics, reusable loaders.
3. **Caching computed results** — the `@cached` produce-or-load layer.
4. **Advanced topics** — URIs in detail, multiple URIs, archives, per-dataset
   locations, lazy access, checksum details, byte-identical manifest output, the
   frozen configuration snapshot, identifier resolution, custom fetch and load
   code.

## Everyday usage

### Reading a manifest

The most straightforward use starts from an existing `Datasets.toml`:

```toml
[herzschuh2023]
doi = "10.1594/PANGAEA.930512"
uri = "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"
extract = true

[jonkers2024]
doi = "10.1594/PANGAEA.962852"
uri = "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"

[jesstierney/lgmDA]
uri = "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
extract = true

[CMIP6_lgm_tos]
uri = "ssh://albedo1.dmawi.de:/albedo/work/projects/p_pool_clim_data/Paleodata/Tierney2020/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"
```

Read it with the `Database` constructor:

```julia
using DataManifest
db = Database("Datasets.toml") # or Database("Datasets.toml", expanduser("~/datasets"))
```

```
Database(
  datasets=Dict(
    CMIP6_lgm_tos => DatasetEntry(uri="ssh:/albedo1.dmawi.de:/albedo/work/projects...),
    herzschuh2023 => DatasetEntry(uri="https:/doi.pangaea.de/10.1594...),
    jonkers2024 => DatasetEntry(uri="https:/download.pangaea.de/dataset/962852/files...),
    jesstierney/lgmDA => DatasetEntry(uri="https:/github.com/jesstierney/lgmDA/archive/refs...),
  ),
  datasets_folder="/home/perrette/.local/share/datamanifest/shared/datasets"
  datasets_toml="/abs/path/to/Datasets.toml"
)
```

If you work in an activated Julia environment (via `julia --project` or
`Pkg.activate(...)`), `Database()` with no arguments looks for a `Datasets.toml`
next to `Project.toml`. The alternative file names `DataManifest.toml` and
`datasets.toml` are also recognized, and the `DATAMANIFEST_TOML` (or
`DATASETS_TOML`) environment variable can point to a manifest explicitly.

### Downloading datasets and getting paths

```julia
download_dataset(db, "jonkers2024") # downloads only if not already present
```

returns the local path, for example:

```
/home/perrette/.local/share/datamanifest/shared/datasets/download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv
```

To get the path without triggering a download, use:

```julia
local_path = get_dataset_path(db, "jonkers2024")
```

All datasets can be downloaded at once:

```julia
download_datasets(db) # downloads every dataset that is not present yet
```

To remove a dataset, `delete_dataset(db, name)` deletes both the manifest entry
and the files on disk (pass `keep_cache=true` to keep the files). Files can of
course also be removed manually with `rm`.

### Loading datasets

`load_dataset(db, name)` downloads the dataset (if needed) and returns a loaded
object. You can pass a loader function; it is called as `loader(path)`:

```julia
data = load_dataset(db, "jonkers2024"; loader = path -> read(path, String))
data = load_dataset(db, "some_csv"; loader = "csv")   # built-in CSV loader
```

If you omit the loader, the entry's `loader` field is used (see
[Reusable loaders](#reusable-loaders-_loaders)), or else a default based on the
dataset's format (e.g. CSV files load with the CSV package when available).

To call a built-in format loader by name, pass `loader="format"` where `format`
is one of: **csv**, **parquet**, **nc**, **dimstack**, **md**, **txt**,
**json**, **yaml**, **yml**, **toml**, **zip**, **tar**, **tar.gz**. Each relies
on an optional package (CSV, Parquet, NCDatasets, …) and errors with an "add
Package" message if that package is not installed.

### Registering datasets from code

Instead of writing the TOML by hand, datasets can be declared from Julia:

```julia
using DataManifest

db = Database(datasets_folder="datasets", persist=false)

register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512",
  extract=true,
)

register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
  name="jonkers2024",
  doi="10.1594/PANGAEA.962852",
)

register_dataset(db, "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip", extract=true)

register_dataset(db, "ssh://albedo1.dmawi.de:/albedo/work/projects/p_forclima/preproc_data_esmvaltool/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"; name="CMIP6_lgm_tos")

println(db)
```

yields:

```
Database:
- CMIP6_lgm_tos => albedo1.dmawi.de/albedo/work/projects/p_forclima/p...
- herzschuh2023 => doi.pangaea.de/10.1594/PANGAEA.930512
- jonkers2024 => download.pangaea.de/dataset/962852/files/LGM_foram...
- jesstierney/lgmDA => github.com/jesstierney/lgmDA.git
datasets_folder: datasets
datasets_toml="" (in-memory database)
```

When `name` is omitted, it is derived from the URI (for git repositories, the
`owner/repo` pair). `DataManifest.add` combines `register_dataset` and
`download_dataset` in one call.

## Configuration

> Every configuration variable, its scopes, and the resolution rule are
> summarized on the [configuration page](configuration.md).

### Where data is stored

Storage reduces to two folder settings:

- **`datasets_dir`** — where fetched datasets land, one per dataset key:
  `<datasets_dir>/<key>`. The default is a machine-global shared store,
  `$user_data_dir/datamanifest/shared/datasets` (on Linux:
  `$XDG_DATA_HOME/...`, falling back to `~/.local/share/...`), shared and
  de-duplicated across projects.
- **`datacache_dir`** — where results produced by `@cached` land:
  `<datacache_dir>/<cachetype>/[<version>/]<hash>/`. The default is per project:
  `$user_cache_dir/datamanifest/projects/$project/cached`.

Both can be set in the manifest's committed `[_STORAGE]` table (e.g.
`datasets_dir = "datasets"` for a repo-local layout), per machine in the
git-ignored `.datamanifest/config.toml` next to the manifest, or user-globally
in `~/.config/datamanifest/config.toml`. Path values may contain `$`-symbols:
the predefined `$user_data_dir`, `$user_cache_dir`, `$repo` and `$project`,
user-defined `[_STORAGE]` keys, environment variables such as `$USER`, and `~`.
Host-specific values go under `[_STORAGE._HOST."<glob>"]`.

When the same setting is defined in several places, the first match on this
ladder wins:

1. `DATAMANIFEST_<NAME>` environment variable
2. checkout config (`.datamanifest/config.toml`)
3. manifest `[_STORAGE._HOST."<glob>"]` (matching this host)
4. manifest `[_STORAGE]`
5. user config (`~/.config/datamanifest/config.toml`)
6. built-in default

The ladder is evaluated once, when the `Database` is created — see
[The frozen configuration snapshot](#the-frozen-configuration-snapshot).

A **read pool** is an extra, read-only location that is checked for a dataset
before downloading; it lets a project reuse data that another project (or
another folder layout) already holds. A few locations (`./datasets/`,
`$user_data_dir/datamanifest/datasets`, `~/.cache/Datasets`) are built-in read
pools, so datasets already present there resolve without a re-download.

Two simpler overrides exist: passing `datasets_folder=` to the `Database`
constructor uses that exact folder for all datasets, and a per-dataset
`storage_path` field relocates a single dataset (see
[Per-dataset locations](#per-dataset-locations-storage_path)).

The full storage reference is in [docs/storage.md](storage.md).

#### Names on disk

Within `datasets_dir`, each dataset occupies `<datasets_dir>/<key>`. The key is
derived from the URI unless you set it explicitly with `key=...` (absolute
paths are also accepted). When a `version` is set (e.g. `version="0.2.5"`), the
name on disk gets a `#0.2.5` suffix. When `extract=true`, the extracted folder
is named after the archive with the archive extension stripped (e.g. `.zip`
removed), or with `.d` appended when there is no recognizable extension (e.g. a
versioned name ending in `#...`).

### Maintaining the manifest file

A `Database` is tied to its `Datasets.toml` by default: registering or deleting
datasets writes the file back. This happens whenever a `datasets_toml=` path was
passed (or found via the active project), unless you opt out with
`persist=false`:

```julia
db = Database(persist=false)
```

```
Database(
  datasets=Dict(
  ),
  datasets_folder="/home/perrette/.local/share/datamanifest/shared/datasets"
  datasets_toml="" (in-memory database)
)
```

An in-memory database can still be written explicitly:

```julia
write(db, "Datasets.toml")
```

The output is sorted: structural `_*` tables (`_META`, `_LANG`, `_LOADERS`,
`_STORAGE`) first, then datasets, both alphabetical — the same top-level order
as the Python implementation of DataManifest. Formatting details (multi-line
vs. inline arrays, indentation of nested tables) differ between the two TOML
libraries; if you need byte-identical files across both tools, see
[Byte-identical manifest output](#byte-identical-manifest-output-canonical).

### Checksum basics

When a dataset is downloaded, its SHA-256 checksum is computed and stored in the
manifest (`checksum = "sha256:..."`). On a later download, the checksum is
verified against the stored value, and a mismatch raises an error. To disable
checksums, set `skip_checksum=true` on the database or on an individual entry.
More detail (when verification runs, accepted field formats) is under
[Checksums in detail](#checksums-in-detail).

### Reusable loaders (`[_LOADERS]`)

A `[_LOADERS]` table in the manifest defines named loaders and a shared context.
(The uppercase name keeps it at the top when the file is sorted.) Two keys set
up the context: **`julia_modules`** (an array of module names to `using`) and
**`julia_includes`** (paths to `include`, relative to the project/TOML
directory). Any other key is a loader name whose value is Julia code that
evaluates to a function; that function is called as `fn(path)`.

```toml
[_LOADERS]
julia_modules = ["CSV"]
julia_includes = ["scripts/loaders.jl"]
read_csv = "path -> CSV.read(path, DataFrame)"

[my_csv]
uri = "https://example.com/data.csv"
loader = "read_csv"
```

An entry's `loader` field can be:

- A **name** matching a key in `[_LOADERS]` — that loader function is used
  (compiled when first needed and cached). The value for that key may itself be
  another loader name (an alias): `md = "txt"` makes `"md"` an alias for the
  `"txt"` loader. Alias cycles are an error.
- A **string** that is not a key in `[_LOADERS]` — it is evaluated in the same
  loader context (after the includes and `using`); the result must be a
  function, which is then called with `(path)`.

When an entry has no `loader`, the default is chosen by format: a loader whose
name (case-insensitively) equals the entry's format is used if defined,
otherwise a built-in default if one exists for that format, otherwise an error.
So defining `csv = "path -> CSV.read(path)"` in `[_LOADERS]` overrides the
default for format `csv`.

From Julia, update the loader section with
`register_loaders(db; loaders=..., julia_modules=..., julia_includes=..., persist=true)`.
Loaders are compiled on first use, which avoids circular dependencies when a
loader's `julia_modules` depends on a package that itself uses DataManifest. To
compile (and validate) loaders eagerly, call `validate_loaders(db)` or
`validate_loader(db, name)`. Prefer minimal code in the TOML and real logic in
included files (e.g. `julia_includes = ["scripts/loaders.jl"]`, with loader
names referring to functions defined there).

## Caching computed results (`@cached`)

`DataManifest.Cache` adds a produce-or-load layer: cache a function's result on
disk, keyed by its parameters rather than by a `uri`.

```julia
@cached cachetype="anomaly" ext="jls" key=(a -> (; a.grid)) function load_anomaly(;
        grid::String="5x5", _verbose::Bool=false)
    # … expensive work …
end
load_anomaly(; grid="5x5")               # computes once; subsequent calls load from disk
load_anomaly(; grid="5x5", cached=false) # escape hatch: run the body, no disk I/O
```

The cache key is the SHA-256 of the canonical JSON of the hash-affecting keyword
parameters (kwargs whose name starts with `_` are runtime knobs and are
excluded). Produced datasets are keyword-only, and hash inputs must be strings,
integers, booleans, finite floats, or arrays/objects of those. Finite floats are
serialized in the normative Python `json.dumps` form; `NaN`, `±Inf` and nulls
raise an error. This keeps the hash identical across the Julia and Python
implementations.

Each artifact is self-describing: a `config.toml` (the re-hashable key table)
and a `metadata.toml` (provenance) sit alongside it at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/` (default
`$user_cache_dir/datamanifest/projects/$project/cached`). The `jls` format is
built in; register other formats with `DataManifest.Cache.register_format!`.

When an artifact is produced, it is registered in the project's **state file**
(`.datamanifest/state.toml`) by its portable `cachetype` + `hash` key, with
`ref = "<module>:<function>"`. State files named `.datamanifest-state.toml` or
`cached.toml` are also read, and moved to the standard name on the next write.
Use `CachedIndex` / `read_index` / `register!` / `write_index` to read or build
one. The file defaults to `<project_root>/.datamanifest/state.toml`; a
`cached_toml` kwarg (declared on the wrapped function) overrides it.

`inspect_store(db)` enumerates produced artifacts and present fetched datasets
as field-bearing `CacheObject`s (`kind`, `key`/`hash`, `format`, `size`,
`created`, `last_access`, `referenced`); `referenced` is resolved from the state
file. Act on a filtered selection with `delete_object` / `move_object` (produced
artifacts only; there is no automatic garbage collection). `last_access` is read
purely from the filesystem at inspect time (the directory's access time, falling
back to the modification time) and is never written on read — it is coarse and
possibly stale. `created`, stamped once at produce time, is the
always-available age signal.

See also [docs/caching.md](caching.md).

## Advanced topics

### URIs and how downloads happen

Most of a dataset's identity lives in its `uri` field. The URI can be an
http(s) address, a github repository (https or `git@`), or an `ssh` address (it
is up to you to keep `.ssh/config` up to date for credentials). `ssh` URIs are
handled by the shell's `rsync`, git repositories by the shell's `git`, and all
other schemes by Julia's `Downloads.download`. For platform-independent access
to data hosted on github, prefer pointing at a release tarball (handled by
`Downloads.download`) over the git repository itself:

```toml
# git-mediated
[tierney2020]
uri = "git@github.com:jesstierney/lgmDA.git"
version = "v2.1"
```

```toml
# preferred: Downloads.download-mediated
[tierney2020]
uri="https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
extract=true
```

DataManifest does not enforce URI strictness — the URI's role can be purely
informative when the download is performed by custom code, or when the file is
user-managed (`skip_download = true`). A URI pointing to a dataset's
documentation page, for example, is a valid use even though DataManifest cannot
fetch from it directly.

### Multiple URIs (`uris`)

When a dataset consists of several files, use the `uris` field (a list) instead
of `uri`. Each URI is downloaded individually into a shared folder. The on-disk
path for each file preserves enough directory structure to avoid name
collisions — the common leading path segments are stripped, so two files at
different sub-paths remain distinguishable.

```toml
[my_collection]
uris = [
  "https://example.com/dataset/v1/file_a.nc",
  "https://example.com/dataset/v1/file_b.nc",
]
# key is auto-derived as "example.com/dataset/v1"
# files land at <datasets_folder>/example.com/dataset/v1/file_a.nc
#                                                          file_b.nc
```

If the files share no common directory (e.g. `data1/file.nc` vs
`data2/file.nc`), the key becomes just the hostname and both sub-paths are
preserved:

```toml
[my_collection]
uris = [
  "https://example.com/data1/file.nc",
  "https://example.com/data2/file.nc",
]
# key = "example.com"
# files land at <datasets_folder>/example.com/data1/file.nc
#                                              data2/file.nc
```

You can always override the key explicitly:

```toml
[my_collection]
key = "my/preferred/folder"
uris = [
  "https://example.com/data1/file.nc",
  "https://example.com/data2/file.nc",
]
```

From Julia, `uri` as a list is also accepted as an alias for `uris`:

```julia
register_dataset(db, ["https://example.com/data1/file.nc", "https://example.com/data2/file.nc"];
    name="my_collection")
# or equivalently:
register_dataset(db, ""; name="my_collection",
    uris=["https://example.com/data1/file.nc", "https://example.com/data2/file.nc"])
```

### Archives

A few archive formats (`zip`, `tar`, `tar.gz`) can be extracted automatically
after download. Set `extract=true` when registering the dataset, or add it to
the TOML entry. With `extract=true`, `get_dataset_path` returns the path to the
extracted folder, and the checksum is computed over the extracted folder rather
than the archive file.

### Per-dataset locations (`storage_path`)

Each dataset has a single location, given by its `storage_path` field — a path
expression that defaults to `$datasets_dir/$key`. Setting it relocates one
dataset without changing anything else: the rest of the pipeline (cache hit,
download, checksum, extraction) is unchanged.

```toml
[in_repo_dataset]
uri = "https://example.com/dataset.csv"      # source
storage_path = "data/dataset.csv"            # relative → resolved against the project root
checksum = "sha256:..."                      # still verified
```

Semantics:

- **Two flavors.** A `storage_path` containing `$key` is a **tool-managed**
  keyed location (DataManifest may delete it via `delete_dataset`). An exact
  path without `$key` is **user-managed**: it is used verbatim, never deleted by
  maintenance, and not subject to read-pool probing.
- **Resolution.** The expression may use `$datasets_dir`, `$key` and the usual
  `$`-symbols. A relative result is resolved against the project root (the
  directory of `Datasets.toml`) — convenient for committing small data files
  alongside your code. An absolute path is used as-is, which is handy for files
  on a NAS, an external drive, or a scratch volume.
- **Cache-hit logic is unchanged.** If the file is already at the resolved
  path, DataManifest returns it without consulting the URI — exactly the
  behavior for files committed to the repository.
- **Cache miss → normal download.** If the file is missing, DataManifest
  downloads from `uri` and writes the result to the resolved path. This lets
  you redirect a fetched dataset into the repository instead of the shared
  store.
- **Checksum still applies.** If `checksum` is set, it is verified against the
  file at the resolved path.

For sources that cannot be fetched automatically (Cloudflare, click-through
agreements, manual logins), combine an exact `storage_path` with
`skip_download = true`: the location comes from `storage_path`, while
`skip_download` makes the user-managed nature explicit and prevents any
download attempt. For files committed to the repository alongside
`Datasets.toml`, this pairing is usually unnecessary: the file is always
present, so the cache hit wins and `uri` is never consulted.

`skip_download = true` used alone (without a `storage_path`) makes
`get_dataset_path` return the `uri` value verbatim as the local path — useful
when the URI already is a local path.

### Lazy access (`lazy_access`)

`lazy_access = true` opens the `uri` in place via a loader (typically a remote
object store) instead of materializing a local copy: no download, no checksum,
no state-file record. It requires a loader that can open the URI — a bare
`lazy_access` with no loader is an error, since there is no local file for a
built-in format loader to read. `lazy_access` is distinct from `skip_download`
(a management mode for user-managed files); the two are independent and do not
combine. Lazily accessed datasets are never deleted by maintenance.

### Checksums in detail

The manifest field is `checksum = "<algo>:<hex>"` (e.g. `sha256:…`, `md5:…`); a
bare hex value is read as SHA-256. A `sha256 = "<hex>"` key is also read and
re-emitted as `checksum` on the next write.

The checksum is computed only when a dataset is actually (re-)fetched. A
present dataset with a `.complete` marker and a non-empty stored checksum is
not re-hashed on every `load_dataset` call. To force re-verification, pass
`overwrite=true` to `download_dataset` (or call `verify_checksum` directly).
On a mismatch, the error message lists the possible resolutions (update or
clear the manifest checksum, or set `skip_checksum`).

### Byte-identical manifest output (`canonical`)

The Julia and Python implementations write the same top-level order but differ
in TOML formatting details. For byte-identical files, pass
`write(db, path; canonical=true)` or set the `canonical` config field to pipe
every persisted manifest through the Python `datamanifest format` CLI.

`canonical` is resolved on the ordinary configuration ladder —
`DATAMANIFEST_CANONICAL` environment variable, the checkout config
(`.datamanifest/config.toml`), the manifest `[_STORAGE]`, the user config
(`~/.config/datamanifest/config.toml`), each with `_HOST` glob support — so
e.g. `canonical = true` in the checkout config enables it for that project on
that machine. Like every config field, it is evaluated once, when the Database
is created (see below).

The CLI is looked up next to the manifest
(`<manifest dir>/.venv/bin/datamanifest`, falling through to the main
checkout's `.venv` when working from a linked git worktree) and then on
`PATH`; when it is absent, the native TOML is written instead (with a warning).

### The frozen configuration snapshot

All configuration (storage folders, `canonical`, and the other ladder-resolved
settings) is evaluated once, when the `Database` is created. The snapshot
includes the config files, the environment variables and the host name, so
every setting has one well-defined value for the database's lifetime — changing
an environment variable afterwards has no effect on an existing `Database`.
Call `freeze_config!(db)` to re-read the config files and environment for an
existing database.

### Identifier resolution

Functions that take a dataset name (`download_dataset`, `get_dataset_path`,
`load_dataset`, `db["name"]`, …) accept, case-insensitively: the dataset's
manifest name, any of its `aliases`, its `doi`, its `key`, or its URI path (for
git repositories, also the bare repository name). Resolution is exact-or-error:
if an identifier matches more than one dataset (a DOI can be shared by several
entries), an error lists the candidates instead of silently picking one —
disambiguate by exact name. `search_dataset` and `search_datasets` expose the
same lookup programmatically.

### Custom fetch and load code (`_LANG`, schema v1)

Schema v1 manifests (`_META.schema = 1`) express custom fetch and load logic as
`module:function` references stored in `_LANG.julia` subtables rather than as
inline Julia code:

```toml
[_META]
schema = 1

[_LANG.julia.loaders]
nc = "MyProject:load_netcdf"        # format-level default loader

[my_dataset._LANG.julia]
fetcher = "MyFetchers:fetch_data"   # custom fetcher ref
loader  = "MyLoaders:load_data"     # custom loader ref
```

A ref `"Module:function"` resolves at runtime via `using Module` +
`getfield(Module, :function)` — no `eval` or `include_string`. See also
[docs/language-bindings.md](language-bindings.md).

#### Resolution ladders

When a dataset is loaded or fetched, the binding is chosen in this order:

- **Load:** the dataset's own `_LANG.julia.loader` → the manifest's
  `[_LANG.julia.loaders][format]` → the built-in default for the format →
  error. Loaders never spawn a subprocess.
- **Fetch:** the dataset's own `_LANG.julia.fetcher` → its
  `_LANG.shell.fetcher` → delegation to the Python `datamanifest` CLI when the
  dataset's bytes can only be produced by a foreign-language fetcher (see
  [language-bindings.md](language-bindings.md)) → the built-in download from
  `uri`/`uris` → error.

#### Parameterized bindings (`{ ref, args, kwargs }`)

Fetcher and loader refs can be written as a TOML inline table to pass explicit
arguments:

```toml
[_META]
schema = 1

[my_dataset._LANG.julia]
fetcher = { ref = "MyFetchers:fetch", args = ["$download_path"], kwargs = { format = "nc" } }
loader  = { ref = "MyLoaders:load",  args = ["$path"],           kwargs = { grid = "5x5" } }
```

At call time:

1. `$var` placeholders in string values are substituted with the dataset
   context:
   - Fetcher: `$download_path`, `$key`, `$uri`, `$version`, `$doi`, `$format`,
     `$branch`, `$project_root`.
   - Loader: `$path` (the materialized file path), plus the same set.
2. The resolved function is called as `ref(subst(args)...; subst(kwargs)...)`.

Non-string values (numbers, arrays, sub-tables) are passed through unchanged.
Bare-string bindings (`fetcher = "Mod:fn"`) are unaffected and keep the
conventional `fn(; download_path=..., ...)` call.

#### Inline code under schema v0

Manifests without `_META.schema` may instead carry inline code, which is read
and executed as written:

- `shell = "<command>"` runs that command instead of the built-in download, with
  the working directory set to the project root (when available) for
  reproducibility. The same template placeholders as above are available
  (`$download_path`, `$project_root`, `$uri`, `$key`, `$version`, `$doi`,
  `$format`, `$branch`). If `$project_root` is used but cannot be determined
  (no activated project, in-memory database), an error is thrown. Complex logic
  (pipes, redirects) should go in a script.
- `julia = "<code>"` runs Julia code in an isolated module (it takes precedence
  over `shell`); use `julia_modules` to load modules before the code. The code
  sees the same variable names as the shell template (`download_path`,
  `project_root`, `uri`, …) plus `entry` (the `DatasetEntry`).

```toml
[my_dataset]
key = "project/data-v1"
shell = "julia scripts/fetch.jl $key $download_path"
```

Under schema v1 (`_META.schema = 1`) these inline execution paths are skipped —
bindings resolve only via `module:function` refs.

#### Multi-language round-trip

Foreign `_LANG.<other>` subtrees (e.g. `[bar._LANG.python]`, maintained by
another language's implementation) and unknown `_*` top-level tables are
preserved verbatim on every read→write cycle. Only `_LANG.julia` is regenerated
from the Julia model.

#### Migrating a v0 manifest

```julia
DataManifest.migrate("Datasets.toml")
```

moves ref-shaped `julia=`/`loader=` per-dataset fields and `[_LOADERS]` ref
entries into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]`, converts a flat
per-dataset `shell = "<cmd>"` field into `[<ds>._LANG.shell].fetcher`, and sets
`_META.schema = 1`. Genuinely inline code is preserved verbatim with a log
note. The call is idempotent.

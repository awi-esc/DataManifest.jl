# Documentation

Be sure you checked the [README](/README.md) first.

## Working from an existing data "manifest" `Datasets.toml`:

Here is the most straightforward use. Have a `Datasets.toml` file with the following content:

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

just read via the `DataManifest.Database` class (or alias `DataManifest.read`), download via `download_dataset` or `download_datasets`

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
    tierney2020 => DatasetEntry(uri="https:/github.com/jesstierney/lgmDA/archive/refs...),
  ),
  datasets_folder="/home/perrette/.cache/Datasets"
  datasets_toml="/abs/path/to/Datasets.toml"
)
```

If you're working in a julia's environment with a `Project.toml` properly activated (via `julia --project` or `Pkg.activate(...)`), the default behaviour is to assume a `Datasets.toml` exists next to `Project.toml`. Note that `datasets.toml` and `DataManifest.toml` are also supported, if they exist.

## Downloading the data and accessing files

```julia
download_dataset(db, "jonkers2024") # will download only if not present
```
which may return something like:
```
/home/perrette/.cache/Datasets/LGM_foraminifera_assemblages_20240110.csv
```

Or more explicitly
```julia
local_path = get_dataset_path(db, "jonkers2024")
```

All datasets can be downloaded at once:
```julia
download_datasets(db) # will download all datasets that are not not present yet
```

At present the datasets on disk must be cleaned manually. I.e. in that case from the shell:
```bash
rm /home/perrette/.cache/Datasets/LGM_foraminifera_assemblages_20240110.csv
```

## Data naming on disk

Fetched datasets land under the resolved **`datasets_dir`** — by default the machine-global
shared store `$user_data_dir/datamanifest/shared/datasets` (Linux:
`$XDG_DATA_HOME/...`, fallback `~/.local/share/...`), shared and de-duplicated across
projects. Earlier default locations (`./datasets/`, `$user_data_dir/datamanifest/datasets`,
`~/.cache/Datasets`) are probed read-only as built-in read pools, so old downloads keep
resolving without a re-download.

Any other folder can be provided by passing `datasets_folder=` when initializing the
`Database` — an exact override of the datasets folder.

When `version=0.2.5` parameter is provided, the name on disk will be appended with `...#0.2.5`.

It is also possible to provide a preferred name on disk via `key=...` to add. The local path will then be provided by `joinpath(store_root, key)` (absolute paths also supported). If `extract=true` is specified, the dataset path for the extracted archive will be either stripped from the archive extension, if the local path ends with the matching archive extension (e.g. ".zip" for the "zip" format), or appended with `.d` in non-obivous case (e.g. no extension, version string `#...`).

## Storage model

Storage reduces to **two folder fields** — `datasets_dir` (fetched datasets, keyed
`<datasets_dir>/<key>`) and `datacache_dir` (the produced cache,
`<datacache_dir>/<cachetype>/[<version>/]<hash>/`). Since spec-v5 they default to
machine-global locations:

```toml
datasets_dir  = "$user_data_dir/datamanifest/shared/datasets"            # shared, keyed
datacache_dir = "$user_cache_dir/datamanifest/projects/$project/cached"  # per-project
```

Set them in the committed `[_STORAGE]` (e.g. `datasets_dir = "datasets"` for a repo-local
layout), or per machine in the git-ignored `.datamanifest/config.toml` / the user-global
`~/.config/datamanifest/config.toml`. Paths interpolate `$`-symbols — predefined
`$user_data_dir` / `$user_cache_dir` / `$repo` / `$project`, user-defined `[_STORAGE]` keys,
`$USER`/env, `~` — host-specific via `[_STORAGE._HOST."<glob>"]`. Resolution ladder (first
match wins): `DATAMANIFEST_<NAME>` env → checkout config → manifest `_HOST` → manifest base
→ user config → built-in default. A per-dataset `storage_path` overrides one dataset's
location (`$key` ⇒ tool-managed; an exact path ⇒ user-managed). Read pools reuse data other
projects already hold. Full reference: [docs/storage.md](storage.md).

## Produce-or-load caching (`@cached`)

`DataManifest.Cache` adds the produce-or-load layer (spec-v3 `cache-produce`): cache a
function's result on disk, keyed by its parameters rather than a `uri`.

```julia
@cached cachetype="anomaly" ext="jls" key=(a -> (; a.grid)) function load_anomaly(;
        grid::String="5x5", _verbose::Bool=false)
    # … expensive work …
end
load_anomaly(; grid="5x5")               # computes once; subsequent calls load from disk
load_anomaly(; grid="5x5", cached=false) # escape hatch: run the body, no disk I/O
```

The key is the SHA-256 of the **canonical JSON** of the hash-affecting keyword parameters
(`_`-prefixed kwargs are runtime knobs, excluded). Produced datasets are **keyword-only**,
and hash inputs are strings/integers/booleans/**finite floats**/arrays/objects of those
(finite floats use the normative Python `json.dumps` form; `NaN`/`±Inf` and nulls raise).
Each artifact is self-describing: `config.toml` (re-hashable key table) and
`metadata.toml` (provenance) sit alongside it at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/` (default
`$user_cache_dir/datamanifest/projects/$project/cached`). `jls` is built in; register other
formats with `DataManifest.Cache.register_format!`.

On a produce, the artifact is registered in the project's **state file**
(`.datamanifest/state.toml`; the legacy `.datamanifest-state.toml` / `cached.toml` names are
still read and relocated on the next write) by its portable `cachetype` + `hash` key, with
`ref = "<module>:<function>"`. Use `CachedIndex` / `read_index` / `register!` /
`write_index` to read or build one. The file defaults to
`<project_root>/.datamanifest/state.toml`; pass a `cached_toml` kwarg (declared on the
wrapped function) to override it.

`inspect_store(db)` (capability `inspect`) enumerates produced artifacts and present fetched
datasets as field-bearing `CacheObject`s (`kind`, `key`/`hash`, `format`, `size`,
`created`, `last_access`, `referenced`); `referenced` is resolved from the state file. Act on a
filtered selection with `delete_object` / `move_object` (produced artifacts only; no automatic
GC). `last_access` is read purely from the filesystem at inspect time (the directory's access
time, falling back to mtime) and is **never written on read** (spec-v3.2) — coarse and
possibly stale; `created` (stamped once at produce time) is the always-available age signal.

## Maintaining a local `Datasets.toml`

The `Database` instance `db` is tied to a `Datasets.toml` definition file by default, provided the `datasets_toml=` is passed as initialization or you work in an active project, unless `persist=false`.

```julia
db = Database(persist=false)
```
will result in:
```
Database(
  datasets=Dict(
  ),
  datasets_folder="/home/perrette/.cache/Datasets"
  datasets_toml="" (in-memory database)
)
```

When the database exists only in memory, it can nonetheless be written explicitly to disk:

```julia
write(db, "Datasets.toml")
```

## Checksum

By default, the sha-256 checksum is computed upon download, unless `Database.skip_checksum === false` or `DatasetEntry.skip_checksum === false`. If the checksum turns out to be
different from the datasets's definition file, an error is raised.

## Archives

A few archive format (currently `zip` and `tar` and `tar.gz`) can be automatically extracted upon download.
Just set `extract=true` to the `register_dataset()` or `add()` command, or add it to your toml definition file.
Note when `extract=true`, the method `get_dataset_path` returns the path to the extracted folder, and the checksum will also be performed on the extracted folder.

## URI

`DataManifest` currently stores most information via the `uri` field. The URI can refer to an http(s) path, a github repository (https or git@) or an `ssh` address (up to the user to have an up-to-date `.ssh/config` to specify passwords etc).
Note `ssh` files are passed on to the shell's `rsync` command, git repositories to the shell's `git`, and all other uri schemes are passed to julia's `Downloads.download`. To have platform-independent dataset available on github, it is recommended to indicate a tarball archive so that `Downloads.download` is used instead of git.

DataManifest does not enforce URI strictness — the URI's role can be purely informative when the download is performed by custom `shell`/`julia` code, or when the file is provided via `local_path` or `skip_download = true`. A URI pointing to a dataset's documentation page, for example, is a valid use even though DataManifest cannot fetch from it directly.

e.g. instead of git-mediated

```toml
[tierney2020]
uri = "git@github.com:jesstierney/lgmDA.git"
version = "v2.1"
```

prefer Download.downloads mediated:
```toml
[tierney2020]
uri="https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
extract=true
```

## Multiple URIs (`uris`)

When a dataset consists of several files, use the `uris` field (a list) instead of `uri`. Each URI is downloaded individually into a shared folder. The on-disk path for each file preserves enough directory structure to avoid name collisions — the common leading path segments are stripped, so two files at different sub-paths remain distinguishable.

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

If the files share no common directory (e.g. `data1/file.nc` vs `data2/file.nc`), the key becomes just the hostname and both sub-paths are preserved:

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

## User-managed local files (`local_path`)

`local_path` overrides the location DataManifest uses for a dataset's local file — replacing the usual `joinpath(datasets_folder, key)` slot with a path the user controls. It is purely a *location override*: the rest of the pipeline (cache-hit, download, checksum, extraction) is unchanged.

```toml
[in_repo_dataset]
uri = "https://example.com/dataset.csv"   # canonical source
local_path = "data/dataset.csv"            # relative → resolved against the Datasets.toml directory
checksum = "sha256:..."                    # still verified
```

Semantics:

- **Resolution.** A relative `local_path` is resolved against the directory of `Datasets.toml` (i.e., your project root) — convenient for committing small data files alongside your code. An absolute `local_path` is used as-is, which is handy for files on a NAS, an external drive, or a scratch volume.
- **No copy into the cache.** The dataset is *not* placed under `datasets_folder` / `key`; `get_dataset_path` returns the resolved `local_path` directly.
- **Cache-hit logic is unchanged.** If the file is already at `local_path`, DataManifest returns it without invoking the URI — exactly the behavior for files that are committed to the repository.
- **Cache miss → normal download.** If the file is missing, DataManifest proceeds with the usual download from `uri` and writes the result to `local_path`. This lets you redirect a fetched dataset into the repo instead of the user's cache directory.
- **Checksum still applies.** If `checksum` is set, it is verified against the file at `local_path`.
- **No deletion.** DataManifest will not remove a `local_path` entry from disk; it never owned the file.

For sources that cannot be fetched automatically (Cloudflare, click-through agreements, manual logins), `local_path` can be combined with `skip_download = true` — the location comes from `local_path`, while `skip_download = true` makes the user-managed nature of the file explicit and prevents any download attempt. For files committed to the repository alongside `Datasets.toml`, this pairing is usually unnecessary: the file is always present, so cache-hit wins and `uri` is never consulted.

Compared with `skip_download = true` used *alone*: the older mechanism overloads `uri` as a path (the URI value is returned verbatim as the local path). `local_path` keeps the two roles distinct — `uri` stays as the source identifier, `local_path` is the on-disk location.

## Schema v1 and the `_LANG` namespace

Schema v1 (`_META.schema = 1`) expresses custom fetch and load logic as `module:function` references stored in `_LANG.julia` subtables rather than as inline Julia code.

```toml
[_META]
schema = 1

[_LANG.julia.loaders]
nc = "MyProject:load_netcdf"        # format-level default loader

[my_dataset._LANG.julia]
fetcher = "MyFetchers:fetch_data"   # custom fetcher ref
loader  = "MyLoaders:load_data"     # custom loader ref
```

A ref `"Module:function"` resolves at runtime via `using Module` + `getfield(Module, :function)` — no `eval` or `include_string`.

### Resolution ladders

**Load** (own `_LANG.julia.loader` → manifest `[_LANG.julia.loaders][format]` → built-in default → error): loaders never spawn a subprocess.

**Fetch** (own `_LANG.julia.fetcher` → `_LANG.shell.fetcher` → `uri`/`uris` → error): delegation to peer CLIs is not yet implemented.

### v0 / v1 split for inline code

Legacy (v0) manifests without `_META.schema` continue to work: inline `julia=`/`loader=` and `[_LOADERS]` are read and executed as before. Under v1 (`schema = 1`) these inline execution paths are skipped — bindings resolve only via `module:function` refs.

### Multi-language round-trip

Foreign `_LANG.<other>` subtrees (e.g. `[bar._LANG.python]`) and unknown `_*` top-level tables are preserved verbatim on every read→write cycle. Only `_LANG.julia` is regenerated from the model.

### Migrating a v0 manifest

```julia
DataManifest.migrate("Datasets.toml")
```

Moves ref-shaped `julia=`/`loader=` per-dataset fields and `[_LOADERS]` ref entries into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]`, then sets `_META.schema = 1`. Genuinely inline code is preserved verbatim with a log note. The call is idempotent.

Also converts a flat per-dataset `shell = "<cmd>"` field into `[<ds>._LANG.shell].fetcher`.

## Parameterized bindings (`{ ref, args, kwargs }`)

Fetcher and loader refs can be written as a TOML inline table to pass explicit arguments:

```toml
[_META]
schema = 1

[my_dataset._LANG.julia]
fetcher = { ref = "MyFetchers:fetch", args = ["$download_path"], kwargs = { format = "nc" } }
loader  = { ref = "MyLoaders:load",  args = ["$path"],           kwargs = { grid = "5x5" } }
```

At call time:

1. `$var` placeholders in string values are substituted with the dataset context:
   - Fetcher: `$download_path`, `$key`, `$uri`, `$version`, `$doi`, `$format`, `$branch`, `$project_root`.
   - Loader: `$path` (the materialized file path), plus the same set.
2. The resolved function is called as `ref(subst(args)...; subst(kwargs)...)`.

Non-string values (numbers, arrays, sub-tables) are passed through unchanged. Bare-string bindings (`fetcher = "Mod:fn"`) are unaffected and keep the conventional `fn(; download_path=..., ...)` call.

## Verify-once integrity

Starting with v0.16.0, SHA-256 checksum is computed **only when actually (re-)fetching** a dataset. A present dataset with a `.complete` marker and a non-empty stored `sha256` is not re-hashed on every `load_dataset` call. To force re-verification, pass `overwrite=true` to `download_dataset`.

## Shell / Julia download commands (v0 / legacy)

When `shell` is set, that command runs instead of the built-in download, with working directory set to the project root (when available) for reproducibility. Use template placeholders `$download_path`, `$project_root`, `$uri`, `$key`, `$version`, `$doi`, `$format`, `$branch`. If `$project_root` is used but cannot be determined (no activated project, in-memory database), an error is thrown. Complex logic (pipes, redirects) should go in a script. Alternatively, set `julia` to run Julia code in an isolated module (takes precedence over `shell`); use `julia_modules` to load modules before the code. The code sees the same variable names as the shell template: `download_path`, `project_root`, `uri`, `key`, `version`, `doi`, `format`, `branch`, plus `entry` (the `DatasetEntry`).

Under schema v1 (`_META.schema = 1`) the `shell=` and `julia=` inline fields are ignored for fetch/load — use `_LANG.julia` refs instead (see above).

```toml
[my_dataset]
key = "project/data-v1"
shell = "julia scripts/fetch.jl $key $download_path"
```

## Loading datasets (load_dataset)

`load_dataset(db, name)` downloads the dataset (if needed) and returns a loaded object. You can pass a **loader** function: it is called as `loader(path)`. If you omit the loader, the entry’s `loader` field is used (see below), or else a format-based default (e.g. CSV when available).

To call a **built-in format loader** by name without defining it in `[_LOADERS]`, pass `loader="format"` where `format` is one of: **csv**, **parquet**, **nc**, **dimstack**, **md**, **txt**, **json**, **yaml**, **yml**, **toml**, **zip**, **tar**, **tar.gz**. Each uses an optional package (CSV, Parquet, NCDatasets, etc.) and will error with an "add Package" message if not installed.

```julia
data = load_dataset(db, "jonkers2024"; loader = path -> read(path, String))
data = load_dataset(db, "some_csv"; loader = "csv")   # built-in CSV loader
```

## Database-level loaders ([_LOADERS])

A TOML **`[_LOADERS]`** section defines reusable loaders and a shared context. The uppercase name keeps it at the top when the file is sorted. Use **`julia_modules`** (array of module names for `using X`) and **`julia_includes`** (paths to `include`, relative to the project/TOML directory). Any other key in `[_LOADERS]` is a loader name whose value is Julia code that **evaluates to a function**; that function is called as `fn(path)`.

An entry’s **`loader`** field can be:
- A **name** that matches a key in `[_LOADERS]` → the corresponding loader function is used (compiled when the TOML is loaded and cached). The value for that key may be Julia code, or **another loader name** (alias); e.g. `md = "txt"` makes `"md"` an alias for the loader `"txt"`. Alias cycles are an error.
- A **string** that is not a key in `[_LOADERS]` → it is evaluated in the same loader context (after includes and `using`); the result must be a function, which is then called with `(path)`.

When an entry has **no** `loader`, the default is chosen by format: if a loader name (case-insensitive) equals the entry's format, that loader is used; otherwise a built-in default is used if available (e.g. `csv`), else an error. So defining `csv = "path -> CSV.read(path)"` in `[_LOADERS]` overrides or provides the default for format `csv`.

From Julia you can update the loader section with **`register_loaders(db; loaders=..., julia_modules=..., julia_includes=..., persist=true)`**. Loaders are compiled on first use (lazy), which avoids circular dependencies when a loader's `julia_modules` depends on a package that itself uses DataManifest. To compile (and validate) loaders explicitly, call **`validate_loaders(db)`** or **`validate_loader(db, name)`**. Prefer minimal code in TOML and real logic in included files (e.g. `julia_includes = ["scripts/loaders.jl"]`, then loader names that reference functions defined there).

Example:

```toml
[_LOADERS]
julia_modules = ["CSV"]
julia_includes = ["scripts/loaders.jl"]
read_csv = "path -> CSV.read(path, DataFrame)"

[my_csv]
uri = "https://example.com/data.csv"
loader = "read_csv"
```

## Low-level declarative syntax

Examples of the declarative syntax.

```julia
using DataManifest

db = Database(datasets_folder="datasets", persist=false) # default: the resolved datasets_dir (shared store)

register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512",
  extract=true,
)

register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
name = "jonkers2024",
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

The newer `DataManifest.add` command combines `register_dataset` and `download_dataset`.

## Data Structure

To be completed. But basically
```julia
db
```
yields
```
Database(
  datasets=Dict(
    CMIP6_lgm_tos => DatasetEntry(uri="ssh://albedo1.dmawi.de:/albedo/work/projects/p_forclima/preproc_data_esmvaltool/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"...),
    herzschuh2023 => DatasetEntry(uri="https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip", doi="10.1594/PANGAEA.930512"...),
    jonkers2024 => DatasetEntry(uri="https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv", doi="10.1594/PANGAEA.962852"...),
    jesstierney/lgmDA => DatasetEntry(uri="git@github.com:jesstierney/lgmDA.git"...),
  ),
  datasets_folder="datasets"
  datasets_toml="" (in-memory database)
)
```

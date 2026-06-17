# Fetchers, loaders, and language bindings

When a dataset needs more than a plain URL download, the manifest can name
functions for DataManifest to run: a **fetcher** obtains the dataset's bytes,
a **loader** opens the fetched file and returns a value. Both are declared as
**bindings** — `"Module:function"` references, never inline code — under
`_LANG.julia` (or bare, in a single-language manifest). The binding forms
(bare and `_LANG`, the parameterized `{ ref, args, kwargs }` table, the
`shell` fetcher), the resolution ladders, and cross-language fetch are part of
the manifest format and documented on the central site:
**[Language bindings](https://perrette.github.io/datamanifest/language-bindings/)**.

This page covers the Julia side: how DataManifest.jl resolves and calls a
binding, the built-in format loaders, and the Julia rungs of the ladders.

```toml
[_META]
schema = 1                          # bindings require the schema header

[sea_ice]
uri    = "https://example.com/sea_ice.nc"
format = "nc"

[sea_ice._LANG.julia]
loader = "MyClimate:load_sea_ice"
```

## How a binding runs in Julia

A ref `"Module:function"` is resolved by `using Module` followed by a
`getfield` lookup — no `eval`, no `include_string` of manifest content. The
module must be importable in the active project; the manifest's project root
is added to the load path, so a module file next to `datamanifest.toml` works as
well as a package dependency.

The call conventions:

- A string-form **loader** is called with one argument, the local path; its
  return value is what `load_dataset(db, "sea_ice")` returns.
- A string-form **fetcher** is called with keyword arguments and must write
  the dataset (a file or a directory) at `download_path`. The keywords passed
  are `download_path`, `project_root`, `entry` (the parsed dataset entry), and
  the metadata fields `uri`, `key`, `version`, `doi`, `format`, `branch`,
  `requires_paths`; accept a trailing `kwargs...` for the ones you do not use.
  The fetcher runs with the project root as its working directory.
- A parameterized binding `{ ref, args, kwargs }` is called as
  `ref(args...; kwargs...)` after `$var` substitution (include `"$path"` in a
  loader's `args`, `"$download_path"` in a fetcher's).

Errors are loud: a binding that is present for Julia — explicit `_LANG.julia`
or bare — resolves or errors, and a runtime failure propagates; there is no
silent fallback to the `uri` or to a default.

## Built-in format loaders

When the manifest declares no loader, built-in defaults cover common formats:
`csv`, `parquet`, `nc`, `dimstack`, `md`, `txt`, `json`, `yaml`/`yml`, `toml`,
`zip`, `tar`, `tar.gz`. They rely on optional packages (CSV, DataFrames,
NCDatasets, …) required at use time; if a package is missing, the loader
errors with the `Pkg.add` command to run. The archive loaders extract to a
temporary directory and return its path. A dataset with `extract = true`
resolves to a directory, so the format default is skipped — such a dataset
needs its own loader to be used with `load_dataset`.

Project-wide format defaults go in `[_LANG.julia.loaders]` (e.g.
`nc = "NCDatasets:Dataset"`); a per-dataset loader always overrides the format
default, and an explicit `loader=` argument to `load_dataset` overrides the
whole ladder.

The built-in format loaders, and any format added with
`DataManifest.register_format!`, live in one **shared format registry** common
to fetched datasets and the produced cache (`@cached`): a format registered as
a cache codec (with a `save` and a `load`) is therefore also loadable as a
dataset through its `load`. The override layer above is unchanged — the named
loaders (`[_LANG.julia.loaders]`, `[_LOADERS]`), a per-dataset `loader`, and an
explicit `loader=` all still beat the registry default. See
[caching.md](caching.md#formats) for the registry and the `format` / `loader` /
`saver` vocabulary.

## The Julia rungs of the ladders

**Fetch** (how the bytes are obtained), first present rung wins:

1. the dataset's own Julia fetcher: `[<ds>._LANG.julia].fetcher`, else the
   bare `fetcher`;
2. the dataset's `shell` command;
3. download from `uri` / `uris` (https, git, ssh/rsync, file, …);
4. **cross-language fetch**: when another language declares a fetcher,
   DataManifest.jl delegates to the Python `datamanifest` CLI when it is on
   `PATH` (it runs `datamanifest download <name>` with `DATAMANIFEST_TOML`
   pointing at the same manifest; the peer materializes the dataset in the
   shared store). `delegate = false` on the dataset disables this;
5. otherwise, a clear "no fetcher" error.

**Load** (`load_dataset` never spawns a subprocess):

1. the dataset's own loader: `[<ds>._LANG.julia].loader`, else the bare
   `loader`;
2. the project format map: `[_LANG.julia.loaders][format]`, else
   `[_LOADERS][format]`;
3. the built-in default for the format;
4. otherwise, an error.

## Lazy access (`lazy_access`)

`lazy_access = true` opens the `uri` in place (typically an object-store URI:
`s3://`, `gs://`, …) instead of materializing a local copy: no download, no
checksum, no state-file record. The loader is called with the `uri` itself, so
a loader that knows how to open it is required; the built-in format defaults
read local files and do not qualify, and DataManifest.jl ships no built-in
remote loader (unlike the Python tool's fsspec loader) — a `lazy_access`
dataset without a loader is an error.

## Older manifests

Manifests without the `[_META] schema = 1` header are read in a legacy mode
where `julia =` / `loader =` fields and `[_LOADERS]` entries may hold inline
code; they keep working as-is. `DataManifest.migrate("datamanifest.toml")`
rewrites such a file in place — ref-shaped fields move into
`[<ds>._LANG.julia]` and `[_LANG.julia.loaders]`, and the `[_META]` header is
added; inline code that cannot become a ref is preserved verbatim with a log
note. The call is idempotent. The legacy inline-code forms themselves are
described in the [walkthrough](doc.md#inline-code-under-schema-v0).

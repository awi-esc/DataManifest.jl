# Fetchers, loaders, and language bindings

When a dataset needs more than a plain URL download, the manifest can name
functions for DataManifest to run:

- A **fetcher** obtains the dataset's bytes: it downloads or builds the data
  and writes the result to a target path.
- A **loader** opens the fetched file and returns a Julia value;
  `load_dataset` calls it.

Both are declared as **bindings**: references to a function, written as a
`"Module:function"` string (a **ref**) — never inline code. At run time a ref
is resolved by `using Module` followed by a `getfield` lookup; no `eval`, no
`include_string` of manifest content. The module must be importable in the
active project; the manifest's project root is added to the load path, so a
module file next to `Datasets.toml` works as well as a package dependency.

Bindings require the schema header at the top of the manifest:

```toml
[_META]
schema = 1
```

## A loader for one dataset

The most common case: a dataset whose file needs custom opening logic.

```toml
[_META]
schema = 1

[sea_ice]
uri    = "https://example.com/sea_ice.nc"
format = "nc"

[sea_ice._LANG.julia]
loader = "MyClimate:load_sea_ice"
```

`_LANG` holds one sub-table per language; DataManifest.jl reads only
`_LANG.julia` and leaves the others to their own implementations (see
[One manifest, several languages](#one-manifest-several-languages)). A
string-form loader is called with one argument, the local path, and its return
value is what `load_dataset("sea_ice")` returns:

```julia
module MyClimate
using NCDatasets
load_sea_ice(path) = NCDataset(path)  # for example
end
```

## A fetcher for one dataset

A dataset that cannot be downloaded from a `uri` — say, the output of a model
run — declares a fetcher instead:

```toml
[model_output]
format = "nc"

[model_output._LANG.julia]
fetcher = "MyClimate:build_model_output"
```

A string-form fetcher is called with keyword arguments and must write the
dataset (a file or a directory) at `download_path`:

```julia
function build_model_output(; download_path, kwargs...)
    # compute, then write the result to download_path
end
```

The keyword arguments passed are `download_path`, `project_root`, `entry` (the
parsed dataset entry), the dataset metadata fields `uri`, `key`, `version`,
`doi`, `format`, `branch`, and `requires_paths`; accept a trailing `kwargs...`
for the ones you do not use. The fetcher runs with the project root as its
working directory.

Errors are loud: a binding that is present for Julia is committed to. If the
ref does not resolve, or the function throws, the error propagates — there is
no silent fallback to the `uri` or to a default.

## Single-language shorthand (bare bindings)

In a manifest not shared with other languages, the `_LANG.julia` wrapper can
be dropped and the binding written directly on the dataset:

```toml
[sea_ice]
uri    = "https://example.com/sea_ice.nc"
format = "nc"
loader = "MyClimate:load_sea_ice"
```

A bare `fetcher` or `loader` is read as the running tool's *own-language*
binding — DataManifest.jl treats it exactly like `_LANG.julia`: same call
convention, same fail-loud behavior. When both are present, the explicit
`_LANG.julia` binding wins. Bare bindings take the string form; the table form
described below belongs to the `_LANG.julia` sites. (Loading a manifest with a
bare `loader` logs a one-time hint to run `migrate`; the binding works
regardless.)

## Format-default loaders

Instead of repeating a loader on every dataset, a format can be mapped to a
loader project-wide:

```toml
[_LANG.julia.loaders]
nc  = "NCDatasets:Dataset"
csv = "MyProject:read_csv"
```

A dataset without its own loader is loaded by the entry matching its `format`
(matched case-insensitively). A per-dataset loader always overrides the format
default. The bare equivalent is a top-level `[_LOADERS]` table (string form
only; it also triggers the one-time `migrate` hint); `[_LANG.julia.loaders]`
is checked first.

When the manifest declares no loader at all, built-in defaults cover common
formats: `csv`, `parquet`, `nc`, `dimstack`, `md`, `txt`, `json`,
`yaml`/`yml`, `toml`, `zip`, `tar`, `tar.gz`. They rely on optional packages
(CSV, DataFrames, NCDatasets, …) required at use time; if a package is
missing, the loader errors with the `Pkg.add` command to run. The archive
loaders (`zip`, `tar`, `tar.gz`) extract to a temporary directory and return
its path. A dataset with `extract = true` resolves to a directory, so the
format default is skipped — such a dataset needs its own loader to be used
with `load_dataset`.

## Parameterized bindings (table form)

At the `_LANG.julia` sites — a dataset's `fetcher`/`loader` and the
`[_LANG.julia.loaders]` map — a binding can also be a table
`{ ref, args, kwargs }`, so one function serves datasets that differ only in
arguments:

```toml
[esm_5x5._LANG.julia.loader]
ref    = "MyClimate:load_esm"
args   = ["$path"]
kwargs = { grid = "5x5", skip_models = ["CESM.*"] }
```

The function is called as `ref(args...; kwargs...)`. Before the call, `$var`
placeholders in string values are substituted — recursively, into nested
arrays and sub-tables — with the dataset's context: `$path` (in loaders) or
`$download_path` (in fetchers), `$uri`, `$key`, `$version`, `$doi`, `$format`,
`$branch`, `$project_root`. A parameterized loader is *not* passed the path
implicitly: include `"$path"` in `args` (likewise `"$download_path"` for a
fetcher). A binding without `args`/`kwargs` — the bare string `"Mod:fn"`,
equivalently `{ ref = "Mod:fn" }` — keeps the conventional call described
above and is written back to the manifest as the string.

## One manifest, several languages

`_LANG` exists so that a single manifest can serve a mixed-language project.
Each implementation runs the bindings in its own namespace and ignores the
others:

```toml
[_LANG.julia.loaders]              # Julia's project-wide format defaults
nc = "NCDatasets:Dataset"

[ocean_temp._LANG.julia]
loader = "MyClimate:load_argo"     # Julia's binding for this dataset

[ocean_temp._LANG.python]
loader = "myclimate.load:argo"     # Python's binding; Julia never runs it
```

When DataManifest.jl rewrites the manifest (for example after
`register_dataset`), foreign `_LANG.<other>` subtrees, bare bindings,
`[_LOADERS]`, and unknown `_*` tables are preserved verbatim; only the Julia
`_LANG` subtree is regenerated. The
[README](../README.md#one-manifest-several-languages) shows a short example,
and the spec's
[`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)
collects more.

## The shell fetcher

The `shell` field is the language-*agnostic* fetcher: one command that every
implementation runs the same way, regardless of language.

```toml
[model_output]
format = "nc"
shell  = "make model_output OUTPUT=$download_path"
```

The command runs in the project root, with `$var` placeholders expanded:
`$download_path` (where the result must be written), `$project_root`, `$uri`,
`$key`, `$version`, `$doi`, `$format`, `$branch`. For datasets with
`requires`, `$requires_paths` (the dependency paths, space-separated) and
`$path_1`, `$path_2`, … are available as well.

## The ladders

A dataset's fetcher and loader are each resolved by walking a fixed list of
rungs — a *ladder* — and taking the first rung that is present.

**Fetch ladder** (how the bytes are obtained):

1. the dataset's own Julia fetcher: `[<ds>._LANG.julia].fetcher`, else the
   bare `fetcher`;
2. the dataset's `shell` command;
3. download from `uri` / `uris` (https, git, ssh/rsync, file, …);
4. **cross-language fetch**: when none of the above is declared but another
   language declares a fetcher, delegate to the peer CLI (next section);
5. otherwise, a clear "no fetcher" error.

**Load ladder** (how `load_dataset` turns the path into a value — it never
spawns a subprocess):

1. the dataset's own loader: `[<ds>._LANG.julia].loader`, else the bare
   `loader`;
2. the project format map: `[_LANG.julia.loaders][format]`, else
   `[_LOADERS][format]`;
3. the built-in default for the format;
4. otherwise, an error. An explicit `loader=` argument to `load_dataset`
   overrides the whole ladder.

A rung is skipped only when it is *absent* (for example, a dataset that
defines only `_LANG.python` bindings has no Julia rung 1). A binding present
for Julia — explicit or bare — resolves or errors, and a runtime failure
propagates; the ladder never falls through to paper over a broken binding.
Dataset lookup follows the same principle: a name, alias, or `doi` matching
more than one dataset is an error naming the candidates, never a silent
first match.

## Cross-language fetch (delegation)

The rare case: a dataset's bytes can be produced only by a fetcher written in
another language — it has no Julia fetcher, no `shell` command, and no `uri`,
but for example a `[<ds>._LANG.python].fetcher`. DataManifest.jl then
**delegates** the fetch to the Python `datamanifest` CLI when it is on `PATH`:
it runs `datamanifest download <name>` with the environment variable
`DATAMANIFEST_TOML` pointing at the same manifest. The peer materializes the
dataset in the shared store, where DataManifest.jl then finds it. Setting
`delegate = false` on the dataset disables delegation. When the CLI is absent,
disabled, or fails, the fetch ends in the ordinary "no fetcher" error.

## Lazy access (`lazy_access`)

Set `lazy_access = true` to open the `uri` *in place* instead of materializing
a local copy: nothing is downloaded, no checksum is verified, nothing is
recorded in the state file, and maintenance commands never touch the dataset.
The loader is called with the `uri` itself as its argument, so a loader is
required — one that knows how to open the `uri` where it lives: a per-dataset
loader, a manifest format loader, or an explicit `loader=` argument. The
built-in format defaults read local files and do not qualify; a `lazy_access`
dataset without a loader is an error.

This is the way to read **object-store** URIs — `s3://`, `gs://`, `gcs://`,
`az://`, `abfs://`, `abfss://`, `adl://`, `gdrive://` — with a scheme-aware
loader. *Downloading* such a URI is not supported natively (there is no
built-in object-store backend); attempting it errors with a pointer to
`lazy_access` or delegation rather than failing silently.

`lazy_access` is distinct from `skip_download`, a management mode in which the
documented local file is used as-is; the two are independent and do not
combine.

## Older manifests

Manifests without the `[_META] schema = 1` header are read in a legacy mode
where `julia =` / `loader =` fields and `[_LOADERS]` entries may hold inline
code; they keep working as-is.

```julia
DataManifest.migrate("Datasets.toml")
```

rewrites such a file in place: ref-shaped fields move into
`[<ds>._LANG.julia]` and `[_LANG.julia.loaders]`, and the `[_META]` header is
added. Inline code that cannot become a ref is preserved verbatim with a log
note. The call is idempotent.

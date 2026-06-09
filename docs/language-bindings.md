# Per-language bindings (`_LANG`)

Custom fetch and load logic lives in a dedicated `_LANG` namespace, so a single
manifest can serve multiple language implementations without conflicts. The
[README](https://github.com/awi-esc/DataManifest.jl/blob/main/README.md#one-manifest-several-languages) shows the short version;
this page is the full behaviour. Bindings are `module:function` references —
never inline code (the snippets below are drawn from the spec's
[`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)):

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

A `"Module:function"` ref is resolved at runtime by `using Module` followed by
`getfield(Module, :function)` — no `eval`, no `include_string`.

## The ladders

**Fetch ladder** (per dataset, in order): own `_LANG.julia.fetcher` (or the bare
`fetcher`) → the dataset's `shell` command → **cross-language fetch (rung 3)** →
`uri`/`uris` → error. Rung 3 is the rare case where a dataset's bytes can be
produced only by a foreign-language fetcher (e.g. `[<ds>._LANG.python].fetcher`):
DataManifest.jl delegates to the Python `datamanifest` CLI when it is on `PATH`
(`datamanifest download <name>`), which materializes the result in the shared
store; it falls through to `uri` when the peer is absent, disabled
(`delegate = false`), or fails.

**Load ladder** (per dataset, in order): own `_LANG.julia.loader` (or the bare
`loader`) → manifest `[_LANG.julia.loaders][format]` (or `[_LOADERS][format]`) →
built-in format default → error. Never spawns a subprocess.

## Access mode — `lazy_access` (spec-v4.3)

Set `lazy_access = true` to open the `uri` *in place* via a loader instead of
materializing a local copy — no download, no checksum, no state-file record, and
maintenance leaves it alone. It **requires a loader** (a bare `lazy_access` with
no loader errors): the loader is what knows how to open the `uri` where it
lives, so this is the natural way to read **object-store** URIs (`s3://`,
`gs://`, `gcs://`, `az://`, `abfs://`, `abfss://`, `adl://`, `gdrive://`) with a
scheme-aware loader. *Downloading* an object-store URI is not natively supported
(no built-in backend) — it errors clearly, pointing you to `lazy_access` or
delegation, rather than failing silently. `lazy_access` is distinct from
`skip_download` (a *management* mode: the documented local file is used as-is).
Identifier resolution is also **exact-or-error**: a name/alias/`doi` matching
more than one dataset is a fail-loud error, never a silent first-match.

## String or table at every site

**Bindings are string or table** at every site (spec-v3.3) — a bare
`module:function` string, or a `{ ref, args, kwargs }` table — including the
project-wide `[_LANG.julia.loaders]` map, so a format default can be
parameterized exactly like a per-dataset loader.

## Language-implicit (bare) bindings

For a single-language project you may skip the `_LANG.julia` wrapper and write a
bare `fetcher`/`loader` directly on the dataset (and a top-level `[_LOADERS]`
format map) — read as the running tool's **own-language** binding (spec-v3.4).
An explicit `_LANG.julia` binding takes precedence. A bare binding is *present*
for Julia, so it is treated like an explicit one — **fail loud** (spec-v3.6): a
resolution failure errors and a runtime error propagates, never a silent
fall-through; the ladder only skips bindings *absent* for Julia (another
language's `_LANG.<other>`). The **`shell`** field is the language-*agnostic*
sibling (spec-v3.5) — the same command for every tool. Foreign `_LANG.<other>`
subtrees, bare bindings, `[_LOADERS]`, and unknown `_*` tables all round-trip
verbatim; only the Julia `_LANG` subtree is regenerated from the model.

## Parameterized bindings

A binding's **table form** carries `args`/`kwargs`, reusing one function across
datasets that differ only in arguments:

```toml
[esm_5x5._LANG.julia.loader]
ref    = "MyClimate:load_esm"
args   = ["$path"]
kwargs = { grid = "5x5", skip_models = ["CESM.*"] }
```

At call time, `$var` placeholders in string values are substituted with the
dataset's context variables (`$download_path` / `$path`, `$key`, `$uri`,
`$version`, `$doi`, `$format`, `$branch`, `$project_root`) and the function is
called as `ref(args...; kwargs...)`. A ref-only binding — the bare string
`"Mod:fn"`, equivalently `{ ref = "Mod:fn" }` — keeps the conventional call and
is written back as the string.

## Migration

```julia
DataManifest.migrate("Datasets.toml")
```

Legacy manifests (no `_META` header, inline `julia=`/`loader=` fields,
`[_LOADERS]`) are still read and executed. `migrate` moves ref-shaped fields
into `[<ds>._LANG.julia]` / `[_LANG.julia.loaders]` and adds the `[_META]`
header; inline code that cannot become a ref is preserved verbatim with a log
note. The call is idempotent.

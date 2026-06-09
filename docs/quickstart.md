# Quick start

In an activated project (`using Pkg; Pkg.activate(...)`):

```julia
using DataManifest

DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")   # resolves under datasets_dir, by default ./datasets/<key>
```

The `add` downloaded the Mauna Loa CO₂ record and wrote one entry to
`Datasets.toml` next to your `Project.toml` — a plain TOML file you can read and
edit by hand, byte-identical to what the sibling Python tool writes:

```toml
[co2]
sha256 = "0058b3788040b5c27b2b5c1dd6d26226b7e4deef85e34c153e64806c37df7c75"
uri = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"
```

**Commit `Datasets.toml`** — it's the recipe (what to fetch and how). The
downloaded data and a local `.datamanifest-state.toml` (which records *where*
each file landed on this machine) stay git-ignored. A collaborator runs
`download_datasets()` to materialize everything.

## Being explicit about the database

To be explicit instead of relying on the activated project, construct a
`Database` yourself:

```julia
db = Database("Datasets.toml", "my-data-folder")
DataManifest.add(db, "https://…"; name="…")
path = get_dataset_path(db, "co2")
```

## File-less database

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
returns the loaded object directly — see [per-language bindings](language-bindings.md).

## Next steps

- [The long-form walkthrough](doc.md) — every feature, end to end.
- [Produce-or-load caching (`@cached`)](caching.md) — cache expensive results.
- [Per-language bindings](language-bindings.md) — `_LANG`, ladders, `lazy_access`.
- [Storage model](storage.md) — where data lands, read pools, the state file.
- [API reference](api.md) — every function and field.

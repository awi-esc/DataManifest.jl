# Quick start

In an activated project (`using Pkg; Pkg.activate(...)`):

```julia
using DataManifest

db = read_dataset("datamanifest.toml")
add(db, "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path(db, "co2")
```

`add` downloaded the Mauna Loa CO₂ record and wrote one entry to
`datamanifest.toml`, next to your `Project.toml`. The manifest is a plain TOML
file you can read and edit by hand:

```toml
[co2]
checksum = "sha256:0058b3788040b5c27b2b5c1dd6d26226b7e4deef85e34c153e64806c37df7c75"
uri = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"
```

By default the data itself is stored outside your repository, in a shared
folder under your user data directory (on Linux,
`~/.local/share/datamanifest/shared/datasets`), so several projects can reuse
the same downloads. `get_dataset_path` returns the resolved on-disk path. To
put data elsewhere — inside the repository, on a scratch disk — see
[storage](storage.md).

## What to commit to git

Commit **`datamanifest.toml`** — it is the recipe: what to fetch and how to verify
it. Everything else stays out of git:

- the downloaded data lives outside the repository (see above);
- the `.datamanifest/` directory, which records where each file landed on
  *this* machine (`state.toml`) and holds per-machine configuration, is
  git-ignored automatically.

A collaborator who clones your repository runs `download_datasets()` to fetch
everything declared in the manifest.

## Loading datasets

`get_dataset_path` gives you a path; `load_dataset` goes one step further and
returns the loaded object. For that, the dataset (or its file format) needs a
**loader**: a reference to a Julia function, written as `"Module:function"` in
the manifest. For example, with `csv = "CSV:File"` declared as a project-wide
loader, `load_dataset("co2")` returns the parsed table directly — see
[fetchers, loaders, and language bindings](language-bindings.md).

## Being explicit about the database

The calls above relied on the activated project to locate the manifest. You
can instead build the `Database` object explicitly:

```julia
db = Database("datamanifest.toml", "my-data-folder")
DataManifest.add(db, "https://…"; name="…")
path = get_dataset_path(db, "co2")
```

## Manifest-less databases

Library code that only wants checksummed downloads into a folder it controls
can skip the manifest entirely with `persist=false`: no `datamanifest.toml`, no
state file, nothing written but the data. The folder accepts the same
`$`-symbols as the storage configuration (`raw"…"` keeps Julia from
interpolating the `$`):

```julia
db = Database(datasets_folder=raw"$user_data_dir/mylib", persist=false)
DataManifest.add(db, "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path(db, "co2")   # → ~/.local/share/mylib/gml.noaa.gov/…/co2_annmean_mlo.csv
```

## Next steps

- [Walkthrough](doc.md) — the main user guide, from everyday usage to advanced topics.
- [Produce-or-load caching (`@cached`)](caching.md) — cache computed results.
- [Fetchers, loaders, and language bindings](language-bindings.md) — custom fetch and load code, `_LANG`, lazy access.
- [Storage](storage.md) — where data lands on disk, read pools, the state file.
- [Configuration](configuration.md) — every configuration variable and how values are resolved.
- [API reference](api.md) — every function and field.

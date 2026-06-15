# Storage: where data lands on disk

The storage model is a property of the manifest format, shared by every
implementation: two folder settings (`datasets_dir` for fetched datasets,
`datacache_dir` for `@cached` artifacts), path expressions with `$`-symbols,
read pools, per-dataset `storage_path`, host-specific `_HOST` values, and the
state file (`.datamanifest/state.toml`). The full treatment
lives on the central site:
**[Storage model](https://perrette.github.io/datamanifest/storage/)** (see
also [Configuration](https://perrette.github.io/datamanifest/configuration/)
for where the settings can be set and which value wins).

On the Julia side, `get_dataset_path(db, name)` resolves a dataset's on-disk
location (recorded location first, then the derived `$datasets_dir/$key`), and
a successful `download_dataset` records the resolved location and checksum in
the state file. The configuration ladder is captured once per `Database` as a
frozen snapshot — see [Configuration](configuration.md).

## Julia API

The Julia-specific entry points behind the model (all in [the API
reference](api.md)):

- **Resolvers** (in the `Storage` module): `Storage.datasets_dir`,
  `Storage.datacache_dir`, `Storage.resolve_symbol`, `Storage.datasets_pools`,
  `Storage.datacache_pools`. Each accepts as `storage_config` a single
  `[_STORAGE]` dict, a vector of layers (`Storage.config_layers`), or a frozen
  `Storage.ConfigSnapshot`. A snapshot is authoritative: its captured
  environment and hostname replace the resolver's own inputs.
- **State file access**: read or build the inventory with `CachedIndex` /
  `read_index` / `register!` / `register_dataset!` / `write_index`. Older
  state-file names (`.datamanifest-state.toml`, `cached.toml`) and schemas are
  still read; the first write migrates them forward.
- **Store maintenance**: `inspect_store(db)` enumerates produced artifacts and
  present fetched datasets as `CacheObject`s (`kind`, `key`/`hash`, `format`,
  `size`, `created`, `last_access`, `referenced`); act on a filtered selection
  with `delete_object` / `move_object`. There is no automatic garbage
  collector — deletion is always an explicit selection, and only produced
  (`cached`) artifacts are eligible.

```julia
db = read_dataset("datamanifest.toml")
for o in inspect_store(db)
    o.kind == "cached" && o.referenced == false && delete_object(o)   # prune orphaned artifacts
end
```

The [`datamanifest` CLI](https://perrette.github.io/datamanifest/cli/) offers
the same maintenance from the shell (`list --orphan --delete`, `refresh`, …)
over the same state file.

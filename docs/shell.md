# Manage your data from the shell

DataManifest.jl ships no CLI of its own — it doesn't need one. The manifest is
language-neutral, and the Python implementation's **`datamanifest`** CLI manages
the same file (it auto-detects `Datasets.toml`): everything around the data —
adding, listing, verifying, repairing, syncing — works from the shell, without
touching your Julia code.

```bash
pip install datamanifestpy
```

```bash
datamanifest list                 # what's tracked, and where it lives
datamanifest add https://host/path/file.nc
datamanifest verify               # re-check every checksum
datamanifest refresh --scan       # repair: reassociate data found on disk
datamanifest push co2 user@hpc    # rsync a dataset to another machine
datamanifest storage              # where data goes on this host
```

See the [Python README](https://github.com/perrette/datamanifest#readme) for
the use cases and the [CLI reference](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
for every command.

## Cross-language fetch

The two tools also cooperate at fetch time: a dataset whose fetcher is written
in Python is materialized by delegating to this same CLI (and the Python tool
can delegate to Julia in turn) — see
[cross-language fetch](language-bindings.md#the-ladders).

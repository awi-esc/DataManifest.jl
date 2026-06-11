# Manage your data from the shell

DataManifest.jl has no command-line interface of its own. The manifest is
language-neutral, and the Python implementation's `datamanifest` CLI (from the
PyPI package `datamanifestpy`) works on the same files the Julia package reads
— the manifest (it auto-detects `Datasets.toml`), the configuration files, and
the state file — so adding, listing, verifying, repairing and syncing data all
work from the shell, without touching your Julia code.

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
datamanifest config show          # resolved configuration, scope by scope
```

`datamanifest config set` edits the same configuration files described on the
[configuration page](configuration.md). See the
[Python README](https://github.com/perrette/datamanifest#readme) for the use
cases and the
[CLI reference](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
for every command.

## Cross-language fetch

The two tools also cooperate at fetch time: a dataset whose fetcher is written
in Python is fetched by delegating to this CLI (and the Python tool can
delegate to Julia in turn) — see
[cross-language fetch](language-bindings.md#cross-language-fetch-delegation).

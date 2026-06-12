# Manage your data from the shell

DataManifest.jl has no command-line interface of its own. The manifest is
language-neutral, and the Python implementation's `datamanifest` CLI (from the
PyPI package `datamanifestpy`, `pip install datamanifestpy`) works on the same
files the Julia package reads — the manifest, the configuration files, and the
state file — so adding, listing, verifying, repairing and syncing data all
work from the shell, without touching your Julia code:

```bash
datamanifest list                 # what's tracked, and where it lives
datamanifest add https://host/path/file.nc
datamanifest verify               # re-check every checksum
datamanifest push co2 user@hpc    # rsync a dataset to another machine
datamanifest config show          # resolved configuration, scope by scope
```

The [CLI reference](https://perrette.github.io/datamanifest/cli/) on the
central site documents every command; the rest of that site covers the shared
concepts (storage, configuration, the manifest format). The two tools also
cooperate at fetch time — a dataset whose fetcher is written in Python is
fetched by delegating to this CLI, and vice versa; see
[cross-language fetch](language-bindings.md#the-julia-rungs-of-the-ladders).

# Installation

`DataManifest.jl` is a registered Julia package:

```julia
using Pkg
Pkg.add("DataManifest")
```

Bleeding edge, straight from the repository:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

It requires Julia 1.10 or newer.

`DataManifest.jl` is still actively developed, with breaking changes until
v1.0.0 is reached.

## Optional dependencies

The core package downloads, verifies, extracts and caches data with no extra
dependencies. Built-in *loaders* for specific formats (CSV, Parquet, NetCDF,
…) use optional packages and only kick in once you add them to your project —
e.g. `Pkg.add("CSV")` to enable the `csv` loader. A loader that needs a package
you have not installed errors with an explicit "add Package" message rather than
failing silently.

## The Python sibling (CLI)

`DataManifest.jl` ships no command-line interface of its own. The manifest
format is [shared across languages](https://github.com/perrette/datamanifest.toml),
and the [Python implementation](https://github.com/perrette/datamanifest)
brings a full `datamanifest` CLI that manages the *same* `Datasets.toml`:

```bash
pip install datamanifestpy
```

See [Manage your data from the shell](shell.md) for the available commands.

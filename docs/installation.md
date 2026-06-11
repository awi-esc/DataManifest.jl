# Installation

DataManifest.jl is a registered Julia package:

```julia
using Pkg
Pkg.add("DataManifest")
```

Development version, straight from the repository:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

It requires Julia 1.10 or newer. DataManifest.jl is still actively developed,
with breaking changes possible until v1.0.0.

## Optional dependencies

The core package downloads, verifies, extracts and caches data with no extra
dependencies. The built-in **loaders** — functions that open a downloaded file
and return a Julia object — rely on optional packages for specific formats
(CSV, Parquet, NetCDF, …) and become available once you add the package to
your project, e.g. `Pkg.add("CSV")` for the `csv` loader. A loader whose
package is missing errors with the `Pkg.add` command to run rather than
failing silently.

## The Python CLI

DataManifest.jl has no command-line interface of its own. The manifest format
is [shared across languages](https://github.com/perrette/datamanifest.toml),
and the [Python implementation](https://github.com/perrette/datamanifest)
provides a `datamanifest` CLI that manages the same `Datasets.toml`:

```bash
pip install datamanifestpy
```

See [Manage your data from the shell](shell.md) for the available commands.

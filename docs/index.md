<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="DataManifest.jl" height="76">
  </picture>
</p>

# DataManifest.jl

DataManifest.jl keeps track of the datasets a scientific project depends on.
You declare each dataset — its URL or git repository, an optional checksum
(a hash of the file contents, used to verify a download), a format — in a
**manifest**: a plain `Datasets.toml` file that lives in your repository.
DataManifest.jl then downloads, verifies, extracts and loads the data on
demand, and can cache your own computed results with the same machinery. The
same manifest is read by a sibling Python tool, which also provides a
command-line interface.

```julia
using Pkg
Pkg.add("DataManifest")
```

```julia
using DataManifest

DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")
```

`add` writes one entry to `Datasets.toml` and downloads the file into a
shared folder under your user data directory; `get_dataset_path` returns the
on-disk path. The [quick start](quickstart.md) walks through this example.

## How the documentation is arranged

This site covers the Julia package: [installation](installation.md), the
[quick start](quickstart.md), the [walkthrough](doc.md), and the
[API reference](api.md). Everything shared across the ecosystem — the storage
and configuration concepts, the manifest format, and the `datamanifest`
command-line interface — is documented once, on the central site:
**<https://perrette.github.io/datamanifest/>**.

## Where to go next

**Getting started**

- [Installation](installation.md) — the package, optional loader packages, the Python CLI.
- [Quick start](quickstart.md) — your first dataset, what to commit, manifest-less databases.

**Guides**

- [Walkthrough](doc.md) — the main user guide, from everyday usage to advanced topics.
- [Produce-or-load caching (`@cached`)](caching.md) — the Julia caching macro.
- [Fetchers, loaders, and language bindings](language-bindings.md) — custom fetch and load code in Julia.
- [Storage](storage.md) and [configuration](configuration.md) — the Julia entry points, with pointers to the central reference.
- [Manage your data from the shell](shell.md) — the `datamanifest` CLI over the same manifest.

**Reference**

- [API](api.md) — every function and field.
- [Ecosystem documentation](https://perrette.github.io/datamanifest/) — concepts, [CLI reference](https://perrette.github.io/datamanifest/cli/), [manifest format](https://perrette.github.io/datamanifest/manifest-format/).

## From the same author

A few other open-source tools I maintain.

**Scientific writing & data**

- [**texmark**](https://perrette.github.io/texmark/) — write scientific articles in Markdown and convert them to journal-ready LaTeX/PDF.
- [**papers**](https://perrette.github.io/papers/) — command-line BibTeX bibliography and PDF library manager.
- [**datamanifest**](https://perrette.github.io/datamanifest/) — the Python implementation of the same manifest format. *(See also the [datamanifest.toml](https://perrette.github.io/datamanifest.toml/) format spec.)*

**Speech to Text (dictate) and Text to Speech (read-aloud) tools**

- [**scribe**](https://perrette.github.io/scribe/) — speech-to-text dictation.
- [**bard**](https://perrette.github.io/bard/) — text-to-speech reader.

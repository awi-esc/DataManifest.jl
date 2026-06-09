<!--
  Home page. The feature bullets are pulled straight from README.md (single
  source of truth) via the include-markdown plugin; everything else links into
  the guide.
-->
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="DataManifest.jl" height="76">
  </picture>
</p>

# DataManifest.jl

Keep track of the datasets used in a scientific project.

{%
  include-markdown "../README.md"
  start="<!-- intro-start -->"
  end="<!-- intro-end -->"
%}

## Get started

```julia
using Pkg
Pkg.add("DataManifest")
```

```julia
using DataManifest
DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")
```

- **[Installation](installation.md)** — the package, optional loaders, the Python CLI sibling.
- **[Quick start](quickstart.md)** — your first dataset, the file-less database.
- **[Documentation walkthrough](doc.md)** — every feature, end to end.
- **[API reference](api.md)** — every function and field.

## Guides

- [Produce-or-load caching (`@cached`)](caching.md) — cache expensive results, keyed by parameters.
- [Per-language bindings](language-bindings.md) — `_LANG`, fetch/load ladders, `lazy_access`, migration.
- [Storage model](storage.md) — where data lands, `$`-symbols, read pools, the state file.
- [Manage your data from the shell](shell.md) — the Python `datamanifest` CLI over the same manifest.

## From the same author

A small toolkit for a Markdown-first scientific workflow.

**Scientific writing & data**

- [**texmark**](https://perrette.github.io/texmark/) — write scientific articles in Markdown and submit them to any journal (Markdown → LaTeX/PDF).
- [**papers**](https://perrette.github.io/papers/) — command-line BibTeX bibliography and PDF library manager.
- [**datamanifest**](https://perrette.github.io/datamanifest/) — declarative, reproducible dataset management. *(See also the [datamanifest.toml](https://perrette.github.io/datamanifest.toml/) format spec and the [DataManifest.jl](https://awi-esc.github.io/DataManifest.jl/) Julia port.)*

**Voice helpers** — handy for dictating and proofreading drafts by ear

- [**scribe**](https://perrette.github.io/scribe/) — speech-to-text dictation (Whisper).
- [**bard**](https://perrette.github.io/bard/) — text-to-speech reader (Kokoro / Piper).

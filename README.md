<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup-dark.svg">
    <img src="https://raw.githubusercontent.com/perrette/datamanifest.toml/main/design/logo/lockup.svg" alt="DataManifest.jl" height="76">
  </picture>
</p>

# DataManifest.jl

[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)
[![docs](https://img.shields.io/badge/docs-awi--esc.github.io%2FDataManifest.jl-blue)](https://awi-esc.github.io/DataManifest.jl/)

Keep track of the datasets used in a scientific project. You declare your data
dependencies — URLs, git repositories, checksums, formats — in a `Datasets.toml`
file; `DataManifest.jl` downloads, verifies, extracts and loads them, and caches
your own computed results with the same machinery. It supports data repositories
such as PANGAEA or Zenodo and git hosts such as GitHub. The manifest format is
[shared across languages](https://github.com/perrette/datamanifest.toml) — the
[reference Python implementation](https://github.com/perrette/datamanifest) reads the
same file, and brings a full command-line interface on top.

<!-- intro-start -->
- **Declare once, fetch anywhere.** Data dependencies — URLs, git repos,
  checksums, formats — live in a plain `Datasets.toml` you commit; a
  collaborator runs `download_datasets()` to materialize everything, verified
  by SHA-256.
- **One manifest, several languages.** The TOML schema is shared across
  implementations, so the same file is read by sibling tools in other languages
  via a `_LANG` namespace — a Julia and a Python project can share one data
  declaration without stepping on each other.
- **Produce-or-load caching.** The `@cached` layer caches the result of an
  expensive computation on disk, keyed by its parameters — reproducible across
  tools, with the same storage machinery as fetched data.
- **Put data where you want it.** Repo-local by default, or point a folder at a
  shared location with `$`-symbols and per-host overrides; read pools reuse data
  another project already fetched.
- **Declarative, no lock-in.** Custom fetch/load logic is a *reference* to
  external code (`Module:function`), not code embedded in the config; the
  manifest stays a plain, hand-editable TOML file.
<!-- intro-end -->

`DataManifest.jl` is still actively developed, with breaking changes until
v1.0.0 is reached.

## Installation

```julia
using Pkg
Pkg.add("DataManifest")
```

See the [installation page](https://awi-esc.github.io/DataManifest.jl/installation/)
for optional format loaders and the Python CLI sibling.

## Quick start

In an activated project:

```julia
using DataManifest

DataManifest.add("https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_annmean_mlo.csv"; name="co2")
path = get_dataset_path("co2")   # resolves under datasets_dir, by default ./datasets/<key>
```

This downloads the dataset and writes one entry to `Datasets.toml` next to your
`Project.toml`. **Commit `Datasets.toml`** — it's the recipe; the downloaded
data and the local `.datamanifest-state.toml` stay git-ignored. See the
[quick start](https://awi-esc.github.io/DataManifest.jl/quickstart/) for the
file-less database and more.

## Documentation

Full documentation lives at **<https://awi-esc.github.io/DataManifest.jl/>**:

- [Installation](https://awi-esc.github.io/DataManifest.jl/installation/)
- [Quick start](https://awi-esc.github.io/DataManifest.jl/quickstart/)
- [Walkthrough](https://awi-esc.github.io/DataManifest.jl/doc/) — every feature, end to end
- [Produce-or-load caching (`@cached`)](https://awi-esc.github.io/DataManifest.jl/caching/)
- [Per-language bindings](https://awi-esc.github.io/DataManifest.jl/language-bindings/) — `_LANG`, ladders, `lazy_access`
- [Storage model](https://awi-esc.github.io/DataManifest.jl/storage/) — read pools, state file, maintenance
- [Manage your data from the shell](https://awi-esc.github.io/DataManifest.jl/shell/) — the Python CLI
- [API reference](https://awi-esc.github.io/DataManifest.jl/api/)

## Conformance

This release targets the **datamanifest.toml spec tag `spec-v4.1`**
(<https://github.com/perrette/datamanifest.toml>); a complete annotated example
manifest lives there
([`examples/datasets.toml`](https://github.com/perrette/datamanifest.toml/blob/main/examples/datasets.toml)).
Implemented capabilities: `lang-read`, `lang-write`, `shell-fetch`, `storage`,
`binding-args`, `byte-identity`, `cache-produce`, `inspect`, `delegation`; only
`sync` (cross-machine `push`/`pull`) is not yet implemented — use the Python CLI
for that.

## Related projects

What sets DataManifest.jl apart is the **cross-language manifest**: it is one
member of a multi-language *DataManifest family* built on a shared TOML schema,
so the same `Datasets.toml` is read by sibling tools in other languages via the
`_LANG` namespace — a Julia and a Python project can share one data declaration
without stepping on each other. Configuration stays **declarative**: custom
logic lives in *references to external Julia code* (`Module:function`) rather
than code embedded in the config file. A casual user still writes three lines to
register and fetch a dataset; the rest is there when a project needs it.

**The DataManifest family (one manifest, many languages):**

- [`perrette/datamanifest.toml`](https://github.com/perrette/datamanifest.toml) — the shared TOML schema spec; the common contract every implementation reads.
- [`perrette/datamanifest`](https://github.com/perrette/datamanifest) — the **reference** Python implementation, sharing the same `Datasets.toml` via the `_LANG` namespace; also the home of the CLI.

**Julia alternatives** (single-language). As a rule of thumb: if you only need code-driven download-and-checksum, DataDeps.jl is lighter; if you want a rich declarative data ecosystem, DataToolkit.jl is richer; DataManifest.jl targets multi-dataset, multi-language scientific projects that want the whole dependency declaration — and its derived-data cache — in one shareable file.

- [`DataDeps.jl`](https://github.com/oxinabox/DataDeps.jl) — download-on-first-access with checksum verification; registration lives in code rather than a manifest file (see [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion).
- [`DataToolkit.jl`](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) — the most comparable: a rich, declarative data-management ecosystem with lazy loading and a broad driver set (the better fit for large driver sets and lazily-loaded web resources; it also allows in-config code via its meta `@syntax`, where DataManifest prefers refs to external code).
- [`DrWatson.jl`](https://juliadynamics.github.io/DrWatson.jl/dev/) — broader scientific-project organization (simulations, file layout, naming), of which data handling is one part.
- [`RemoteFiles.jl`](https://github.com/helgee/RemoteFiles.jl) — keep a local file in sync with a remote URL.
- Pkg Artifacts (`Artifacts.toml`) — Julia's built-in TOML manifest of content-addressed, hash-pinned data/binary bundles tied to packages.

## From the same author

A small toolkit for a Markdown-first scientific workflow.

**Scientific writing & data**

- [**texmark**](https://perrette.github.io/texmark/) — write scientific articles in Markdown and submit them to any journal (Markdown → LaTeX/PDF).
- [**papers**](https://perrette.github.io/papers/) — command-line BibTeX bibliography and PDF library manager.
- [**datamanifest**](https://perrette.github.io/datamanifest/) — declarative, reproducible dataset management. *(See also the [datamanifest.toml](https://perrette.github.io/datamanifest.toml/) format spec and the [DataManifest.jl](https://awi-esc.github.io/DataManifest.jl/) Julia port.)*

**Voice helpers** — handy for dictating and proofreading drafts by ear

- [**scribe**](https://perrette.github.io/scribe/) — speech-to-text dictation (Whisper).
- [**bard**](https://perrette.github.io/bard/) — text-to-speech reader (Kokoro / Piper).

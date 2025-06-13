[![CI](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml/badge.svg)](https://github.com/awi-esc/DataManifest.jl/actions/workflows/ci.yaml)

# DataManifest.jl

Keep track of datasets used in a project.

Provide a simple and straightforward way to keep track of datasets downloaded from the web.

Currently DataManifest supports download from a set of URLs suited for repositories like PANGEA or ZENODO, as well as git-based repositories such as github. Support for more remote repositories will be added along the way as necessary.

It provides declarative functions to register and download datasets, as well as a way to write to and read from an equivalent (and optional) `toml` config file.

`DataManifest.jl` is still actively developped, with breaking changes until v1.0.0 is reached (see [roadmap](#roadmap) below).

## How to install?

This package can be installed as:
```julia
using Pkg
Pkg.add("DataManifest")
```
and the bleeding edge can be installed directly via:

```julia
Pkg.add(url="https://github.com/awi-esc/DataManifest.jl")
```

## Usage

Let's assume you work in an activated package (`using Pkg; Pkg.activate(...)`) with a `Project.toml`.
The simplest way to add a dataset is as follow:

```julia
using DataManifest;
DataManifest.add("https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"; extract=true, name="jesstierney/lgmDA")
```
will generate `Datasets.toml` next to your `Project.toml` with the content

```toml
["jesstierney/lgmDA"]
uri = "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
sha256 = "da5f85235baf7f858f1b52ed73405f5d4ed28a8f6da92e16070f86b724d8bb25"
extract = true
```
and download and extract the corresponding dataset, which can be accessed via
```julia
get_dataset_path("jesstierney/lgmDA")  # defaults to ~/.cache/Datasets/...
```

If you're not working in an activated environment, or want to be more explicit for your readers, you can specify the paths and simply prefix every command with the loaded database:
```julia
db = Database("datasets.toml", "my-data-folder")
DataManifest.add(db, ...)
path = get_datasets_path(db, ...)
```

or even work with in-memory database (the toml, not the data), if you don't mind about checksums etc
```julia
db = Database(datasets_folder="my-data-folder", persist=false)
add(db, ...) # will simply download things and update db without writing any toml to disk
```

## Documentation

See the [full documentation](/docs/doc.md) and the [API](/docs/api.md).


## Roadmap

Nothing at this point. After some time of usage and feedbacks, the roadmap will be updated, and eventually I'll make the v1.0.0 release.

## Why DataManifest.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757), [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl) and [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. See [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion of `DataDeps.jl`.  **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **DataManifest.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. I'd say if DataManifest.jl ever attempts to get past the download and on-disk management of datasets, with things like actual data loaders including lazy loading of web ressources, it should probably stop right there and use DataToolKits instead.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). I dislike the idea of having data loaders included as this massively overburdens the core functionality (keep track of things), and examples provided in DataToolKit to clean-up datasets were not convincing to me: too much is kept hidden with ugly meta `@syntax` mixed in the config files, were normal functions could do the job. Also I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **DataManifest.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.

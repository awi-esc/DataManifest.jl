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

### Working from an existing data "manifest" `datasets.toml`:


Here is the most straightforward use. If a `datasets.toml` file already exists:

```toml
[herzschuh2023]
doi = "10.1594/PANGAEA.930512"
uri = "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"

[jonkers2024]
doi = "10.1594/PANGAEA.962852"
uri = "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"

[tierney2020]
uri = "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"

[CMIP6_lgm_tos]
uri = "ssh://albedo1.dmawi.de:/albedo/work/projects/p_pool_clim_data/Paleodata/Tierney2020/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"
```

just read via the `DataManifest.Database` class (or alias `DataManifest.read`), download via `download_dataset` or `download_datasets`

```julia
using DataManifest
db = Database("datasets.toml") # or Database("datasets.toml", expanduser("~/datasets"))
```

### Downloading the data and accessing files

```julia
download_dataset(db, "jonkers2024") # will download only if not present
```
which may return something like:
```
/home/perrette/.cache/Datasets/LGM_foraminifera_assemblages_20240110.csv
```

Or more explicitly
```julia
local_path = get_dataset_path(db, "jonkers2024")
```

All datasets can be downloaded at once:
```julia
download_datasets(db) # will download all datasets that are not not present yet
```

At present the datasets on disk must be cleaned manually. I.e. in that case from the shell:
```bash
rm /home/perrette/.cache/Datasets/LGM_foraminifera_assemblages_20240110.csv
```

### Data naming on disk

The default folder is `$XDG_CACHE_HOME/Datasets/` or `.cache/Datasets/` if `XDG_CACHE_HOME` environment variable is not defined (see [XDG specifications](https://specifications.freedesktop.org/basedir-spec/latest/)).
Any other folder, such as a local folder, can be provided by passing `datasets_path=` when initializing the `Database`.
Note the datasets naming scheme is still pretty much "in flux" trying to balance clarity and uniqueness. When a DOI is provided, it will be used in place of the remote address to build the path. When `version=0.2.5` parameter is provided, the name on disk will be appended with `...#0.2.5`.

### Bundle `add` command

```julia
db = Database()
DataManifest.add(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512")
```

This command updates the in-memory database `db`, add the `herzschuh2023` item,
and download its content to the default folder.


### Maintaining a local `datasets.toml`

At the moment the `Database` instance `db` exists only in memory, and it is up to the user to
write it to disk.

```julia
write(db, "datasets.toml")
```

We are considering automatically writing to a projects' `datasets.toml` file by default when the `add` command is used (see [roadmap](#roadmap)).


### Archives

This is still experimental, but `zip` and `tar` and `tar.gz` archives can (and by default are) automatically extracted upon download. See [#roadmap](roadmap).


### URI

`DataManifest` currently stores most information via the `uri` field. The URI can refer to an http(s) path, a github repository (https or git@) or an `ssh` address (up to the user to have an up-to-date `.ssh/config` to specify passwords etc).
Note `ssh` files are passed on to the shell's `rsync` command, git repositories to the shell's `git`, and all other uri schemes are passed to julia's `Downloads.download`. To have platform-independent dataset available on github, it is recommended to indicate a tarball archive so that `Downloads.download` is used instead of git.

e.g. instead of git-mediated

```toml
[tierney2020]
uri = "git@github.com:jesstierney/lgmDA.git"
ref = "v2.1"
```

prefer Download.downloads mediated:
```toml
[tierney2020]
uri="https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
```

### Low-level declarative syntax

Examples of the declarative syntax.

```julia
using DataManifest

db = Database(datasets_path="datasets") # the default is ~/.cache/DataManifest

register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512",
)

register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
name = "jonkers2024",
doi="10.1594/PANGAEA.962852",
)

register_dataset(db, "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"; name="jesstierney/lgmDA")

register_dataset(db, "ssh://albedo1.dmawi.de:/albedo/work/projects/p_forclima/preproc_data_esmvaltool/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"; name="CMIP6_lgm_tos")

println(db)
```
yields:
```
Database:
- CMIP6_lgm_tos => albedo1.dmawi.de/albedo/work/projects/p_forclima/p...
- herzschuh2023 => doi.pangaea.de/10.1594/PANGAEA.930512
- jonkers2024 => download.pangaea.de/dataset/962852/files/LGM_foram...
- jesstierney/lgmDA => github.com/jesstierney/lgmDA.git
datasets_path: datasets
```

The newer `DataManifest.add` command combines `register_dataset` and `download_dataset`.

## Data Structure

To be completed. But basically
```julia
db
```
yields
```
Database(
  datasets=Dict(
    CMIP6_lgm_tos => DatasetEntry(uri="ssh://albedo1.dmawi.de:/albedo/work/projects/p_forclima/preproc_data_esmvaltool/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"...),
    herzschuh2023 => DatasetEntry(uri="https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip", doi="10.1594/PANGAEA.930512"...),
    jonkers2024 => DatasetEntry(uri="https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv", doi="10.1594/PANGAEA.962852"...),
    jesstierney/lgmDA => DatasetEntry(uri="git@github.com:jesstierney/lgmDA.git"...),
  ),
  datasets_path="datasets"
)
```

## Roadmap

Before the package is stabilized, the following points must be addressed (implemented or rejected), mainly related to the `DataManifest.add()` function:
- automatically update an actual data manifest file (instead of currently just reading from it, or writing on demand)?
- perhaps use Project.toml to store the data when is used, like `Pkg.add`?
- better handle the archives (.zip), e.g. download a full zenodo archive like `https://zenodo.org/api/records/15230504/files-archive`, from the "Download All" button on [this page](https://zenodo.org/records/15230504) -> must be up to the user to decide to extract (or not extract) a voluminous archive.

## Why DataManifest.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757), [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl) and [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. See [Issue #1](https://github.com/awi-esc/DataManifest.jl/issues/1) for a discussion of `DataDeps.jl`.  **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **DataManifest.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. I'd say if DataManifest.jl ever attempts to get past the download and on-disk management of datasets, with things like actual data loaders including lazy loading of web ressources, it should probably stop right there and use DataToolKits instead.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). I dislike the idea of having data loaders included as this massively overburdens the core functionality (keep track of things), and examples provided in DataToolKit to clean-up datasets were not convincing to me: too much is kept hidden with ugly meta `@syntax` mixed in the config files, were normal functions could do the job. Also I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **DataManifest.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.

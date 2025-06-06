# Datasets.jl

Keep track of datasets used in a project.

Provide a simple and straightforward way to keep track of datasets downloaded from the web.

Currently Datasets supports download from a set of URLs suited for repositories like PANGEA or ZENODO, as well as git-based repositories such as github. Support for more remote repositories will be added along the way as necessary.

It provides declarative functions to register and download datasets, as well as a way to write to and read from an equivalent (and optional) `toml` config file.

## How to install?

This package is not registerd, so you need to install it from URL:

```julia
using Pkg
Pkg.add(url="https://github.com/awi-esc/Datasets.jl")
```

## Examples

Here is the most straightforward use, e.g. in a `datasets.toml` file:

```toml
[herzschuh2023]
doi = "10.1594/PANGAEA.930512"
uri = "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"

[jonkers2024]
doi = "10.1594/PANGAEA.962852"
uri = "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"

[tierney2020]
uri = "git@github.com:jesstierney/lgmDA.git"
ref = "v2.1"

[CMIP6_lgm_tos]
uri = "ssh://albedo1.dmawi.de:/albedo/work/projects/p_pool_clim_data/Paleodata/Tierney2020/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"
```

And read via the `Datasets.Database` class (alias for reading `Datasets.read`), download via `download_dataset` or `download_datasets`

```julia
using DataFrames
using Datasets
db = Database("datasets.toml") # or Database("datasets.toml", expanduser("~/datasets"))
folder = download_dataset(db, "jonkers2024") # will download only if not present
df = CSV.read(joinpath(folder, "LGM_foraminifera_assemblages_20240110.csv"), DataFrame)
```

## Advanced Examples

Examples of the declarative syntax
```julia

using Datasets

db = Database(datasets_path="datasets") # the default is ~/.cache/Datasets

register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512",
)

register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
name = "jonkers2024",
doi="10.1594/PANGAEA.962852",
)

register_dataset(db, "git@github.com:jesstierney/lgmDA.git")

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


## Why Datasets.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) and [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **Datasets.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. I'd say if Datasets.jl ever attempts to get past the download and on-disk management of datasets, with things like actual data loaders including lazy loading of web ressources, it should probably stop right there and use DataToolKits instead.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). I dislike the idea of having data loaders included as this massively overburdens the core functionality (keep track of things), and examples provided in DataToolKit to clean-up datasets were not convincing to me: too much is kept hidden with ugly meta `@syntax` mixed in the config files, were normal functions could do the job. Also I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **Datasets.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.

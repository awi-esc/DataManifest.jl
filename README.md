# Datasets

Keep track of datasets used in a project.

Provide a simple and straightforward way to keep track of datasets downloaded from the web.

Currently Datasets supports download from a set of URLs suited for repositories like PANGEA or ZENODO, as well as git-based repositories such as github. Support for more remote repositories will be added along the way as necessary.

It provides declarative functions to register and download datasets, as well as a way to write to and read from an equivalent (and optional) `toml` config file.

## Examples

Examples of the declarative syntax
```julia

using Datasets

# Datasets.DATASETS_PATH = "datasets" # default

register_dataset("herzschuh2021"; doi="10.1594/PANGAEA.930512",
    downloads=["https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"],
)

register_dataset("jonkers2024"; doi="10.1594/PANGAEA.962852",
    downloads=["https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"],
)

register_repository("git@github.com:jesstierney/lgmDA.git"; name="tierney2020")

println(DATASETS)
```
yields:
```
Dict{Any, Any} with 3 entries:
  "herzschuh2021" => Dict{String, Any}("downloads"=>["https://doi.pangaea.de/10…
  "jonkers2024"   => Dict{String, Any}("downloads"=>["https://download.pangaea.…
  "tierney2020"   => Dict{String, Any}("aliases"=>AbstractString["jesstierney/l…
```

An equivalent declaration can be defined in a toml file for more clarify (that's what I'd recommended):

```toml
[herzschuh2021]
downloads = ["https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"]
doi = "10.1594/PANGAEA.930512"

[jonkers2024]
downloads = ["https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"]
doi = "10.1594/PANGAEA.962852"

[tierney2020]
remote = "git@github.com:jesstierney/lgmDA.git"
```

Note dataset-specific parameters can be provided to overwrite global parameters such as `datasets_path`.

And read via the `register_datasets` function

```julia

datasets = register_datasets("config.yml")
```

At present there is a global variable `DATASETS` that contains all datasets,
so that is it not needed as an input argument to the functions, but
optional parameters make it possible to handle separate dataset files.

Finally, the datasets can be downloaded straightforwardly:

```julia
download_dataset("jonkers2024")
download_datasets()  # download all datasets defined in DATASETS
```

That files will be downloaded to their `folder` key, which defaults to a local `datasets` folder,
and will then use their DOI if provided, or the github remote, or their name / alias otherwise.

See the [example notebook](example.ipynb).


## Why Datasets.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) and [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **Datasets.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. I'd say if Datasets.jl ever attempts to get past the download and on-disk management of datasets, with things like actual data loaders including lazy loading of web ressources, it should probably stop right there and use DataToolKits instead.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). I dislike the idea of having data loaders included as this massively overburdens the core functionality (keep track of things), and examples provided in DataToolKit to clean-up datasets were not convincing to me: too much is kept hidden with ugly meta `@syntax` mixed in the config files, were normal functions could do the job. Also I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **Datasets.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.
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
downloads = ["https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"]
doi = "10.1594/PANGAEA.930512"

[jonkers2024]
downloads = ["https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"]
doi = "10.1594/PANGAEA.962852"

[tierney2020]
remote = "git@github.com:jesstierney/lgmDA.git"
```

And read via the `register_datasets` function, download via `download_dataset` or `download_datasets`

```julia
using DataFrames
using Datasets
set_datasets_path(expanduser("~/datasets"))
register_datasets("datasets.yml")
folder = download_dataset("jonkers2024") # will download only if not present
df = CSV.read(joinpath(folder, "LGM_foraminifera_assemblages_20240110.csv"), DataFrame)
```

## Pre-compilation vs run-time: mind the global state when used inside a module

Here we're dealing with the following situation: in a julia project (i.e. with a Project.toml) you have
a DataModule that relies on `Datasets.jl`. It imports it, register the relevant datasets, perhaps even
download the required files. What usually happens is the DataModule module is pre-compiled, and its state is cached and later re-used. However, `Datasets`'s global state is not part of the cache, so any work done there is wiped out. Given the default behaviour of "hiding" the database object inside `Datasets`' global, any initialization done during pre-compilation will be lost, i.e. any Datasets' work done at or executed from the module's top-level.

Several strategies can be used to overcome this problem:

1. Move the storage to your module state: Define a `DATASETS = Dict()` in your module, to be used as storage  instead of
   the GLOBAL_STATE in `Datasets`, and always pass  `datasets=DATASETS` to functions like `register_datasets` and `download_dataset(s)`.
   Your module state will persist (recommended option).

```julia
module DataModule
export read_jonkers2024, TIERNEY2020
using Datasets
DATASETS = Dict()
register_datasets(joinpath(@__DIR__, "..", "datasets.toml"),
    datasets=DATASETS, datasets_path=expanduser("~/datasets"))
TIERNEY2020 = download_dataset("tierney2020", datasets=DATASETS)

function read_jonkers2024()
    folder = download_dataset("jonkers2024", datasets=DATASETS)
    # ... do work with it
end
end # module
```

2. Alternatively, if you want to stick to global storage, you avoid doing anything during pre-compilation and use the handy `__init__()` function that is not run
during pre-compilation and initializes module at run-time.

```julia
module DataModule
export read_jonkers2024, TIERNEY2020
using Datasets

"will be called at run-time when the module is loaded (not during pre-compulation)"
function __init__()
    global TIERNEY2020
    set_datasets_path(expanduser("~/datasets"))
    register_datasets(joinpath(@__DIR__, "..", "datasets.toml"))
    TIERNEY2020 = download_dataset("tierney2020")
end


function read_jonkers2024()
    folder = download_dataset("jonkers2024") # run-time (relies on __init__)
    # ... do work with it
end

end # module
```

And of course, if initialization is needed during pre-compilation you can have a separate `init_datasets` function called at top-level and also called inside the module;

```julia
function init_datasets()
    global TIERNEY2020
    set_datasets_path(expanduser("~/datasets"))
    register_datasets(joinpath(@__DIR__, "..", "datasets.toml"))
    TIERNEY2020 = download_dataset("tierney2020")
end

function __init__()
    init_datasets()  # called at run-time
end

init_datasets() # called during pre-compilation
```

## Advanced Examples

Examples of the declarative syntax
```julia

using Datasets

set_datasets_path("datasets") # default

register_dataset("herzschuh2023"; doi="10.1594/PANGAEA.930512",
    downloads=["https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"],
)

register_dataset("jonkers2024"; doi="10.1594/PANGAEA.962852",
    downloads=["https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"],
)

register_repository("git@github.com:jesstierney/lgmDA.git"; name="tierney2020")

println(get_datasets())
```
yields:
```
Dict{Any, Any} with 3 entries:
  "herzschuh2023" => Dict{String, Any}("downloads"=>["https://doi.pangaea.de/10…
  "jonkers2024"   => Dict{String, Any}("downloads"=>["https://download.pangaea.…
  "tierney2020"   => Dict{String, Any}("aliases"=>AbstractString["jesstierney/l…
```

The (meta)database is stored in a global state `Datasets.GLOBAL_STATE["DATASETS"]`.
However, for specific cases such as for a library or when several conflictual datasets
must co-exist, an optional parameter `datasets::Dict` can be passed to relevant functions
that is then used in place of the global `Datasets.GLOBAL_STATE["DATASETS"]` variable.

Similarly, there is a global `Datasets.GLOBAL_STATE["DATASETS_PATH"]` variable that defines the default
root folder for saving all datasets, which defaults to a local `datasets` folder.
The global variable
can be overwritten using the function `set_datasets_path(...)`
or passed as `datasets_path=` keyword argument to the `register_...` functions.
Each dataset has its own `folder` path. It is built from their DOI, if provided,
or the github remote, or their name otherwise (and is a child of the datasets' path).
In case a specific dataset must be stored in a different location than the rest,
the full `folder` path can be provided directly as key-word argument
to `register_dataset(s)` / `register_repository`,
or assigned as `folder` key to one of the datasets' items,
or written in the `datasets.toml` file (this is not recommended when the project
is to be distributed, because each user should be free to organize their data as they please,
based on their specific architecture).


## Why Datasets.jl ?

It seems there are quite a few tools to help project and data management. What I stumbled upon includes [Dr Watson](https://juliadynamics.github.io/DrWatson.jl/dev/), [DataToolKit.jl](https://discourse.julialang.org/t/ann-datatoolkit-jl-reproducible-flexible-and-convenient-data-management/104757) and [RemoteFiles.jl](https://github.com/helgee/RemoteFiles.jl). RemoteFiles.jl does not provide enough documentation for me to judge at this stage. **Dr Watson** aims at assisting with all aspects of how to organize files in a scientific project, including running simulations etc, and as such it has a broader scope than **Datasets.jl**. **DataToolKit.jl** is the only package I actually tried. What I can say is it is impressive because it merges apparent simplicity of use depth of functionality. I'd say if Datasets.jl ever attempts to get past the download and on-disk management of datasets, with things like actual data loaders including lazy loading of web ressources, it should probably stop right there and use DataToolKits instead.

What made me publish this package instead of just relying on DataTookKit.jl is the KISS principle (Keep It Simple & Stupid). I dislike the idea of having data loaders included as this massively overburdens the core functionality (keep track of things), and examples provided in DataToolKit to clean-up datasets were not convincing to me: too much is kept hidden with ugly meta `@syntax` mixed in the config files, were normal functions could do the job. Also I found it not straightforward to use the files as they are downloaded (thinking about a zip file that contained CSV data in need of custom loading) and it was not immediately clear to me how to store files on disk (it might be possible though!). Anyway, the **DataToolKit.jl** project is very good and has a dedicated main developer giving talks and it will evolve and you should check it out! For now though, **Datasets.jl** is so simple and tiny that it can be useful for whoever wants to follow the KISS principle.

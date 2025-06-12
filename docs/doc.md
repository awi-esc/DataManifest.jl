# Documentation

Be sure you checked the [README](/README.md) first.

## Working from an existing data "manifest" `Datasets.toml`:

Here is the most straightforward use. Have a `Datasets.toml` file with the following content:

```toml
[herzschuh2023]
doi = "10.1594/PANGAEA.930512"
uri = "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip"
extract = true

[jonkers2024]
doi = "10.1594/PANGAEA.962852"
uri = "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv"

[jesstierney/lgmDA]
uri = "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
extract = true

[CMIP6_lgm_tos]
uri = "ssh://albedo1.dmawi.de:/albedo/work/projects/p_pool_clim_data/Paleodata/Tierney2020/LGM/recipe_cmip6_lgm_tos_20241114_151009/preproc/lgm/tos_CLIM"
```

just read via the `DataManifest.Database` class (or alias `DataManifest.read`), download via `download_dataset` or `download_datasets`

```julia
using DataManifest
db = Database("Datasets.toml") # or Database("Datasets.toml", expanduser("~/datasets"))
```

```
Database(
  datasets=Dict(
    CMIP6_lgm_tos => DatasetEntry(uri="ssh:/albedo1.dmawi.de:/albedo/work/projects...),
    herzschuh2023 => DatasetEntry(uri="https:/doi.pangaea.de/10.1594...),
    jonkers2024 => DatasetEntry(uri="https:/download.pangaea.de/dataset/962852/files...),
    tierney2020 => DatasetEntry(uri="https:/github.com/jesstierney/lgmDA/archive/refs...),
  ),
  datasets_folder="/home/perrette/.cache/Datasets"
  datasets_toml="/abs/path/to/Datasets.toml"
)
```

If you're working in a julia's environment with a `Project.toml` properly activated (via `julia --project` or `Pkg.activate(...)`), the default behaviour is to assume a `Datasets.toml` exists next to `Project.toml`. Note that `datasets.toml` and `DataManifest.toml` are also supported, if they exist.

## Downloading the data and accessing files

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

## Data naming on disk

The default folder is `$XDG_CACHE_HOME/Datasets/` or `.cache/Datasets/` if `XDG_CACHE_HOME` environment variable is not defined (see [XDG specifications](https://specifications.freedesktop.org/basedir-spec/latest/)).
Any other folder, such as a local folder, can be provided by passing `datasets_folder=` when initializing the `Database`.
Note the datasets naming scheme is still pretty much "in flux" (though hopefully stabilizing by now), trying to balance clarity and uniqueness.
When `version=0.2.5` parameter is provided, the name on disk will be appended with `...#0.2.5`.

It is also possible to provide a preferred name on disk via `key=...` to add. The local path will then be provided by `joinpath(datasets_folder, key)` (absolute paths also supported). If `extract=true` is specified, the dataset path for the extracted archive will be either stripped from the archive extension, if the local path ends with the matching archive extension (e.g. ".zip" for the "zip" format), or appended with `.d` in non-obivous case (e.g. no extension, version string `#...`).

## Maintaining a local `Datasets.toml`

The `Database` instance `db` is tied to a `Datasets.toml` definition file by default, provided the `datasets_toml=` is passed as initialization or you work in an active project, unless `persist=false`.

```julia
db = Database(persist=false)
```
will result in:
```
Database(
  datasets=Dict(
  ),
  datasets_folder="/home/perrette/.cache/Datasets"
  datasets_toml="" (in-memory database)
)
```

When the database exists only in memory, it can nonetheless be written explicitly to disk:

```julia
write(db, "Datasets.toml")
```

## Checksum

By default, the sha-256 checksum is computed upon download, unless `Database.skip_checksum === false` or `DatasetEntry.skip_checksum === false`. If the checksum turns out to be
different from the datasets's definition file, an error is raised.

## Archives

A few archive format (currently `zip` and `tar` and `tar.gz`) can be automatically extracted upon download.
Just set `extract=true` to the `register_dataset()` or `add()` command, or add it to your toml definition file.
Note when `extract=true`, the method `get_dataset_path` returns the path to the extracted folder, and the checksum will also be performed on the extracted folder.

## URI

`DataManifest` currently stores most information via the `uri` field. The URI can refer to an http(s) path, a github repository (https or git@) or an `ssh` address (up to the user to have an up-to-date `.ssh/config` to specify passwords etc).
Note `ssh` files are passed on to the shell's `rsync` command, git repositories to the shell's `git`, and all other uri schemes are passed to julia's `Downloads.download`. To have platform-independent dataset available on github, it is recommended to indicate a tarball archive so that `Downloads.download` is used instead of git.

e.g. instead of git-mediated

```toml
[tierney2020]
uri = "git@github.com:jesstierney/lgmDA.git"
version = "v2.1"
```

prefer Download.downloads mediated:
```toml
[tierney2020]
uri="https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip"
extract=true
```

## Low-level declarative syntax

Examples of the declarative syntax.

```julia
using DataManifest

db = Database(datasets_folder="datasets", persist=false) # the default is ~/.cache/Datasets

register_dataset(db, "https://doi.pangaea.de/10.1594/PANGAEA.930512?format=zip";
  name="herzschuh2023",
  doi="10.1594/PANGAEA.930512",
  extract=true,
)

register_dataset(db, "https://download.pangaea.de/dataset/962852/files/LGM_foraminifera_assemblages_20240110.csv";
name = "jonkers2024",
doi="10.1594/PANGAEA.962852",
)

register_dataset(db, "https://github.com/jesstierney/lgmDA/archive/refs/tags/v2.1.zip", extract=true)

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
datasets_folder: datasets
datasets_toml="" (in-memory database)
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
  datasets_folder="datasets"
  datasets_toml="" (in-memory database)
)
```

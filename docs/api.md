## `add`

```
add([db::Database], uri::String="";
    name::String="",
    overwrite::Bool=false,
    persist::Bool=true,
    check_duplicate::Bool=true,
    skip_download::Bool=false,
    version::String="",
    branch::String="",
    doi::String="",
    aliases::Vector{String}=String[],
    key::String="",
    sha256::String="",
    skip_checksum::Bool=false,
    skip_download::Bool=false,
    extract::Bool=false,
    format::String=""
) -> Pair{String, DatasetEntry}
```

Add a dataset to the database, downloading it if necessary.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- If `name` is not provided, it is inferred from the URI or dataset entry.
- All keyword arguments (except for internal fields) correspond to fields in `DatasetEntry`.
- If `skip_download` is `false` (default), the dataset will be downloaded after registration.

**Arguments:**
- `db::Database` (optional): The database to add the dataset to.
- `uri::String`: The dataset URI.
- `name::String`: Name for the dataset.
- `overwrite::Bool`: Overwrite existing entry if present.
- `persist::Bool`: Persist changes to disk.
- `check_duplicate::Bool`: Check for duplicate entries.
- `skip_download::Bool`: Skip downloading the dataset after registration.
- `version::String`: Version or tag for the dataset.
- `branch::String`: Branch for git repositories.
- `doi::String`: DOI for the dataset.
- `aliases::Vector{String}`: Alternative names for the dataset.
- `key::String`: Unique key for the dataset.
- `sha256::String`: SHA-256 checksum.
- `skip_checksum::Bool`: Skip checksum verification.
- `extract::Bool`: Extract the dataset after download.
- `format::String`: File format (e.g., "zip", "tar").

**Returns:**
A pair `(name => entry)` where `entry` is the registered `DatasetEntry`.

---

## `get_dataset_path`

```
get_dataset_path([db::Database], name::String; extract::Union{Nothing,Bool}=nothing) -> String
get_dataset_path([db::Database], entry::DatasetEntry; extract::Union{Nothing,Bool}=nothing) -> String
get_dataset_path(name::String; extract::Union{Nothing,Bool}=nothing) -> String
```

Return the local path for a dataset entry, based on its scheme, host, path, and version.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- You can provide either the dataset name or a `DatasetEntry` object.
- The `extract` keyword controls whether the path points to the extracted folder (if applicable).

**Arguments:**
- `db::Database` (optional): The database to search in.
- `name::String`: The name of the dataset.
- `entry::DatasetEntry`: The dataset entry.
- `extract::Union{Nothing,Bool}`: Whether to return the path to the extracted folder.

**Returns:**
The local path as a `String`.

---

## `Database`

```
Database(;
    datasets_toml::String="",
    datasets_folder::String="",
    persist::Bool=true,
    skip_checksum::Bool=false,
    skip_checksum_folders::Bool=false,
    datasets::Dict{String, DatasetEntry}=Dict{String, DatasetEntry}()
) -> Database

Database(datasets_toml::String, datasets_folder::String=""; kwargs...) -> Database
```

Create a new dataset database.

- If `datasets_folder` is not provided, defaults to `~/.cache/Datasets`.
- If `datasets_toml` is not provided and `persist` is `true`, attempts to infer a TOML file from the project or environment.
- If a TOML file is provided and exists, datasets are loaded from it.

**Arguments:**
- `datasets_toml::String`: Path to the TOML file for persistence.
- `datasets_folder::String`: Path to the datasets folder.
- `persist::Bool`: Whether to persist changes to disk.
- `skip_checksum::Bool`: Skip SHA-256 checksum verification.
- `skip_checksum_folders::Bool`: Skip checksum verification for folders.
- `datasets::Dict{String, DatasetEntry}`: Initial datasets.

**Returns:**
A `Database` object.

---

**Note:**
For all functions, if the `db::Database` argument is omitted, the default database is used, which requires that a Julia project is activated and a datasets TOML file is available or can be inferred.



## `search_datasets`

```
search_datasets([db::Database], name::String; alt=true, partial=false) -> Vector{Pair{String, DatasetEntry}}
```

Search for datasets in the database by name or alternative keys, returning all matches as a vector of `(name => entry)` pairs.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- The search is **case-insensitive** and proceeds in the following order:

### Search Logic and Field Priority

1. **Exact match on dataset name** (the main key in the database).
2. **Exact match on alternative keys** (if `alt=true`):
    - Any value in the `aliases` field (alternative names).
    - The `doi` field (if present).
    - The `key` field (unique key for the dataset).
    - The `path` field.
3. **Partial match on dataset name** (if `partial=true`):
   Checks if `name` is a substring of any dataset name.
4. **Partial match on alternative keys** (if `alt=true` and `partial=true`):
   Checks if `name` is a substring of any value in the alternative keys listed above.

All matches found in the above order are returned.

**Arguments:**
- `db::Database` (optional): The database to search in.
- `name::String`: The name, alias, DOI, key, or path of the dataset.
- `alt::Bool`: Whether to search alternative keys (default: `true`).
- `partial::Bool`: Whether to allow partial (substring) matches (default: `false`).

**Returns:**
A vector of `(name => entry)` pairs for all matching datasets.

---

## `search_dataset`

```
search_dataset([db::Database], name::String; raise=true, alt=true, partial=false) -> Tuple{String, DatasetEntry}
```

Search for a dataset by name or alternative keys in the database, returning the first match as a tuple `(name, entry)`.

- The search logic and field priority are the same as in [`search_datasets`](#search_datasets).
- If no match is found and `raise=true` (default), an error is thrown. If `raise=false`, returns `nothing`.
- If multiple matches are found, an error is thrown (or a warning if `raise=false`).

**Arguments:**
- `db::Database` (optional): The database to search in.
- `name::String`: The name, alias, DOI, key, or path of the dataset.
- `raise::Bool`: Whether to throw an error if no match or multiple matches are found (default: `true`).
- `alt::Bool`: Whether to search alternative keys (default: `true`).
- `partial::Bool`: Whether to allow partial (substring) matches (default: `false`).

**Returns:**
A tuple `(name, entry)` where `entry` is the found `DatasetEntry`.

**Note:**
You can also access a dataset entry directly by name using indexing syntax:
```julia
entry = db["dataset_name"]
```
This is equivalent to `search_dataset(db, "dataset_name")[2]`.

---

## `DatasetEntry`

```
struct DatasetEntry
    uri::String = ""
    version::String = ""
    branch::String = ""           # For git repositories
    doi::String = ""
    aliases::Vector{String} = []
    key::String = ""              # Unique key for the dataset, usually the DOI or a unique name
    sha256::String = ""
    skip_checksum::Bool = false   # Whether to skip SHA-256 checksum checks for this dataset
    skip_download::Bool = false   # Skip download (e.g. to keep local files out of the download folder)
    extract::Bool = false         # Whether to extract the dataset after downloading
    format::String = ""           # File format (e.g., "zip", "tar")
end
```

A `DatasetEntry` holds metadata and configuration for a dataset.
It is initialized via the `add` method (and internally, `register_dataset` and `init_dataset_entry`).

**Fields:**
- `uri::String`: The dataset URI (required).
- `version::String`: Version or tag for the dataset.
- `branch::String`: Branch for git repositories.
- `doi::String`: DOI for the dataset.
- `aliases::Vector{String}`: Alternative names for the dataset.
- `key::String`: Unique key for the dataset.
- `sha256::String`: SHA-256 checksum.
- `skip_checksum::Bool`: Skip checksum verification for this dataset.
- `skip_download::Bool`: Skip downloading this dataset.
- `extract::Bool`: Extract the dataset after download.
- `format::String`: File format (e.g., "zip", "tar").

**Note:**
Fields such as `host`, `path`, and `scheme` are internal and not documented here.

---
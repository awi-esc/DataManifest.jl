module DataManifest

using TOML
using URIParser
using Logging
using SHA
import Downloads
import Base: write

export get_dataset_path
export Database, DatasetEntry
export register_dataset, register_datasets
export search_datasets, search_dataset
export download_dataset, download_datasets
export set_datasets_folder, set_datasets, get_datasets_folder, get_datasets
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export repr_short, string_short
export write
export verify_checksum
export add_dataset, read_dataset

_console_logger = ConsoleLogger(Info; show_limited=true, right_justify=0)

function meta_formatter(level::LogLevel, _module, group, id, file, line)
    color, prefix, suffix = _console_logger.meta_formatter(level, _module, group, id, file, line)
    return (
        color,
        "DataManifest",
        suffix,
    )
end

logger = ConsoleLogger(Info; show_limited=true, right_justify=0, meta_formatter=meta_formatter)

function info(msg::String)
    with_logger(logger) do
        @info(msg)
    end
end

function warn(msg::String)
    with_logger(logger) do
        @warn(msg)
    end
end

function sha256_file(file_path)
    # Open the file in binary read mode
    open(file_path, "r") do file
        # Initialize a SHA-256 context
        ctx = SHA256_CTX()

        # Read the file in chunks and update the hash context
        buffer = Vector{UInt8}(undef, 1024) # Create a buffer to read chunks of the file
        while !eof(file)
            bytes_read = readbytes!(file, buffer)
            update!(ctx, buffer[1:bytes_read])
        end

        # Finalize the hash and convert to hexadecimal
        file_hash = bytes2hex(digest!(ctx))
        return file_hash
    end
end


function sha256_folder(folder_path)
    # Initialize a SHA-256 context
    ctx = SHA256_CTX()

    # Walk through the directory
    for (root, dirs, files) in walkdir(folder_path)
        for file in files
            file_path = joinpath(root, file)

            # Open the file and read it in binary mode
            open(file_path, "r") do f
                # Update the hash context with the file contents
                while !eof(f)
                    data = read(f, 1024) # Read in chunks of 1024 bytes
                    update!(ctx, data)
                end
            end
        end
    end

    # Finalize the hash
    folder_hash = bytes2hex(digest!(ctx))
    return folder_hash
end

function sha256_path(path::String)
    if isfile(path)
        return sha256_file(path)
    elseif isdir(path)
        return sha256_folder(path)
    else
        error("Path does not exist: $path")
    end
end

XDG_CACHE_HOME = get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
DEFAULT_DATASETS_FOLDER_PATH = joinpath(XDG_CACHE_HOME, "Datasets")
DEFAULT_DATASETS_TOML_PATH = ""
COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]
KNOWN_EXTENSIONS = ["."*fmt for fmt in COMPRESSED_FORMATS]
HIDE_STRUCT_FIELDS = [:host, :path, :scheme]

"""
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

A `DatasetEntry` holds metadata and configuration for a dataset.
It is initialized via the `add` method (and internally, `register_dataset` and `init_dataset_entry`).

# Fields
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

# Note
Fields such as `host`, `path`, and `scheme` are internal and not documented here.
"""
@kwdef mutable struct DatasetEntry
    uri::String = ""
    host::String = ""
    path::String = ""
    scheme::String = ""
    version::String = ""
    branch::String = "" # for git repositories
    doi::String = ""
    aliases::Vector{String} = Vector{String}()
    key::String = "" # Unique key for the dataset, usually the doi or a unique name
    sha256::String = ""
    skip_checksum::Bool = false  # Whether to skip SHA-256 checksum checks for this dataset
    skip_download::Bool = false  # skip download (e.g. to keep local files out of the download folder)
    extract::Bool = false  # Whether to extract the dataset after downloading. If true, the key will point to the extracted folder
    format::String = ""  # For now used for archive in combination with the extract flag. zip or tar etc.. useful if the uri's path does not end with a known extension
end


function Base.:(==)(a::DatasetEntry, b::DatasetEntry)
    if typeof(a) != typeof(b)
        return false
    end
    for field in fieldnames(typeof(a))
        if (field in [:sha256, :skip_checksum])
            continue  # Skip sha256 field for equality check
        end
        if getfield(a, field) != getfield(b, field)
            return false
        end
    end
    return true
end

function to_dict(entry::DatasetEntry)
    output = Dict{String,Union{String,Vector{String},Bool}}()
    for field in fieldnames(typeof(entry))
        value = getfield(entry, field)
        if (field in HIDE_STRUCT_FIELDS)
            continue
        end
        if (value === nothing || value == [] || value == Dict() || value === "" || value == false)
            continue
        end
        if (field == :key)
            if value == build_dataset_key(entry)
                continue  # Skip the key if it matches the default key
            end
        end
        if (field == :format)
            if value == guess_file_format(entry)
                continue  # Skip the key if it matches the default key
            end
        end
        output[String(field)] = value
    end
    return output
end

# This method controls the default string output,
# e.g. when you call string(x) or print(x)
function Base.string(x::DatasetEntry)
    return "$(typeof(x)):\n$(join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))),"\n"))"
end

function Base.show(io::IO, x::DatasetEntry)
    # print(io, "$(typeof(x)):\n", join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))), "\n"))
    print(io, Base.string(x))
end

function string_short(x::DatasetEntry)
    short = x.key
    # if length(short) > 50
    #     short = "$(short[1:50])..."
    # end
    return short
end

function trimstring(s::String, n::Int; path=true)
    if length(s) <= n
        return s  # If the string is already short enough, return as is
    end
    if !path
        return s[1:n] * "..."  # If not a path, just truncate and add ellipsis
    end
    while length(s) > n
        parts = splitpath(s)
        if length(parts) <= 1
            return s  # If there's no more parts to remove, return as is
        end
        s = joinpath(parts[1:end-1])  # Remove the last part of the path
    end
    return s * "..."
end

function Base.repr(x::DatasetEntry)
    return "$(typeof(x))($(join(("$k=$(trimstring(repr(v), 30))" for (k, v) in pairs(to_dict(x))), ", ")))"
end

function repr_short(x::DatasetEntry)
    s = "$(typeof(x))($(join(("$k=$(trimstring(repr(v), 50))" for (k, v) in pairs(to_dict(x)) if k in ["uri"]), ", "))...)"
    return replace(s, "......" => "...")
end

# # This method controls the representation used by repr(x)
# # and is also the one the REPL uses by default.
function Base.show(io::IO, ::MIME"text/plain", x::DatasetEntry)
    print(io, Base.repr(x))
end

"""
    Database(; datasets_toml::String="", datasets_folder::String="", persist::Bool=true,
        skip_checksum::Bool=false, skip_checksum_folders::Bool=false,
        datasets::Dict{String, DatasetEntry}=Dict{String, DatasetEntry}()) -> Database

    Database(datasets_toml::String, datasets_folder::String=""; kwargs...) -> Database

Create a new dataset database.

- If `datasets_folder` is not provided, defaults to `~/.cache/Datasets`.
- If `datasets_toml` is not provided and `persist` is `true`, attempts to infer a TOML file from the project or environment.
- If a TOML file is provided and exists, datasets are loaded from it.

# Arguments
- `datasets_toml::String`: Path to the TOML file for persistence.
- `datasets_folder::String`: Path to the datasets folder.
- `persist::Bool`: Whether to persist changes to disk.
- `skip_checksum::Bool`: Skip SHA-256 checksum verification.
- `skip_checksum_folders::Bool`: Skip checksum verification for folders.
- `datasets::Dict{String, DatasetEntry}`: Initial datasets.

# Returns
A `Database` object.
"""
mutable struct Database
    datasets::Dict{String,<:DatasetEntry}
    datasets_toml::String
    datasets_folder::String
    skip_checksum::Bool  # Whether to check SHA-256 checksums for datasets
    skip_checksum_folders::Bool # Whether to skip SHA-256 checksums for folders

    function Database(;datasets_toml::String="", datasets_folder::String="",
        persist::Bool=true, skip_checksum::Bool=false, skip_checksum_folders::Bool=false,
        datasets::Dict{String,<:DatasetEntry}=Dict{String,DatasetEntry}(), kwargs...)
        if datasets_folder == ""
            datasets_folder = DEFAULT_DATASETS_FOLDER_PATH
        end
        if (datasets_toml == "" && persist)
            datasets_toml = get_default_toml()
        end
        db = new(
            datasets,
            persist && datasets_toml != "" ? abspath(datasets_toml) : "",
            datasets_folder,
            skip_checksum,
            skip_checksum_folders,
        )
        if (isfile(datasets_toml))
            register_datasets(db, datasets_toml; kwargs...)
        end

        return db
    end

    function Database(datasets_toml::String, datasets_folder::String=""; kwargs...)
        return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
    end

end

Base.getindex(db::Database, name::String) = search_dataset(db, name)[2]

function Base.:(==)(db1::Database, db2::Database)
    return db1.datasets == db2.datasets && db1.datasets_folder == db2.datasets_folder && db1.datasets_toml == db2.datasets_toml
end

function to_dict(db::Database; kwargs...)
    return Dict(key => to_dict(entry; kwargs...) for (key, entry) in pairs(db.datasets))
           Dict("datasets_folder" => db.datasets_folder)
end

# This method controls the default string output,
# e.g. when you call string(x) or print(x)
function Base.show(io::IO, db::Database)
    print(io, "$(typeof(db))")
    if length(db.datasets) == 0
        print(io, " (Empty)\n")
    else
        print(io, ":\n")
    end
    for (k, v) in pairs(db.datasets)
        s = "- $k => $(string_short(v))"
        s = trimstring(s, 80; path=false)
        print(io, s*"\n")
    end
    print(io, "datasets_folder: $(db.datasets_folder)\n")
    if db.datasets_toml != ""
        print(io, "datasets_toml: $(db.datasets_toml)")
    else
        print(io, "datasets_toml: $(repr(db.datasets_toml)) (in-memory database)")
    end
end

# This method controls the representation used by repr(x)
# and is also the one the REPL uses by default.
function Base.show(io::IO, ::MIME"text/plain", db::Database)
    print(io, "$(typeof(db))(\n")
    print(io, "  datasets=Dict(\n")
    for (k, v) in pairs(db.datasets)
        print(io, "    $k => ", repr_short(v), ",\n")
    end
    print(io, "  ),\n")
    print(io, "  datasets_folder=$(repr(db.datasets_folder))\n")
    if db.datasets_toml != ""
        print(io, "  datasets_toml=$(repr(db.datasets_toml))\n)")
    else
        print(io, "  datasets_toml=\"\" (in-memory database)\n)")
    end
end

function TOML.print(io::IO, db::Database; kwargs...)
    return TOML.print(io, to_dict(db); kwargs...)
end

function TOML.print(db::Database; kwargs...)
    return TOML.print(to_dict(db); kwargs...)
end

function write(db::Database, datasets_toml::String; kwargs...)

    # ensure any error in TOML conversion won't leave an empty file
    toml_string = sprint(TOML.print, db; kwargs...)

    if (toml_string === nothing)
        error("Failed to convert Database to TOML string.")
    end

    open(datasets_toml, "w") do io
        write(io, toml_string)
    end
end

"""Accessor functions for back-compatibility
"""
function set_datasets_folder(db::Database, path::String)
    db.datasets_folder = path
end

function set_datasets(db::Database, datasets::Dict{String,<:DatasetEntry})
    db.datasets = datasets
end

function get_datasets_folder(db::Database, datasets_folder::String="")
    if datasets_folder != ""
        return datasets_folder
    end
    return db.datasets_folder
end

function get_datasets_toml(db::Database, datasets_toml::String="")
    if datasets_toml !== ""
        return datasets_toml
    end
    return db.datasets_toml
end

function get_datasets(db::Database)
    return db.datasets
end

"""
Parse URI string to extract host, path, scheme, version/ref, doi, etc.
"""
function parse_uri_metadata(uri::String)
    if startswith(uri, "git@")
        # Convert git@host:path to git://host/path
        scheme = "git"
        uri = replace(uri, ":" => "/")
        uri = replace(uri, "git@" => "git://")
    end

    parsed = URI(uri)
    host = parsed.host
    scheme = parsed.scheme
    path = rstrip(parsed.path, '/')
    fragment = parsed.fragment

    # Parse query parameters like ?version=xxx or ?ref=xxx
    query = Dict{String,String}()
    for q in split(parsed.query, "&")
        kv = split(q, "=")
        if length(kv) == 2
            query[kv[1]] = kv[2]
        end
    end

    version = get(query, "version", "")
    ref = get(query, "ref", "")
    format = get(query, "format", "")

    return (
        uri=uri,
        scheme=scheme,
        host=host,
        path=path,
        format=format,
        version=fragment !== "" ? fragment : (version !=="" ? version : ref),
    )

end

"""
Build key for local path naming of a dataset entry, based on scheme, host, path and version.
"""
function build_dataset_key(entry::DatasetEntry, path::String="")

    clean_path = strip(path == "" ? entry.path : path, '/')

    key = joinpath(entry.host, clean_path)

    if (entry.version !== "")
        key = key * "#$(entry.version)"
    end

    return strip(key, '/')
end

"""
Return local path for dataset entry, based on scheme, host, path and version.
"""
function get_dataset_key(entry::DatasetEntry)

    if entry.key !== ""
        return entry.key
    end

    return build_dataset_key(entry)
end

"""
    get_dataset_path([db::Database], name::String; extract::Union{Nothing,Bool}=nothing) -> String
    get_dataset_path([db::Database], entry::DatasetEntry; extract::Union{Nothing,Bool}=nothing) -> String
    get_dataset_path(name::String; extract::Union{Nothing,Bool}=nothing) -> String

Return the local path for a dataset entry, based on its scheme, host, path, and version.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- You can provide either the dataset name or a `DatasetEntry` object.
- The `extract` keyword controls whether the path points to the extracted folder (if applicable).

# Arguments
- `db::Database` (optional): The database to search in.
- `name::String`: The name of the dataset.
- `entry::DatasetEntry`: The dataset entry.
- `extract::Union{Nothing,Bool}`: Whether to return the path to the extracted folder.

# Returns
The local path as a `String`.
"""
function get_dataset_path(entry::DatasetEntry, datasets_folder::String=""; extract::Union{Bool,Nothing}=nothing)

    if (entry.skip_download)
        return entry.uri
    end

    if (extract === nothing)
        extract = entry.extract
    end

    key = entry.key

    if extract
        key = get_extract_path(key)
    end

    return joinpath(
        datasets_folder !== "" ? datasets_folder : DEFAULT_DATASETS_FOLDER_PATH,
        key,
    )
end

function get_dataset_path(db::Database, name::String; extract=nothing, kwargs...)
    (name, dataset) = search_dataset(db, name; kwargs...)
    return get_dataset_path(dataset, db.datasets_folder; extract=extract)
end

function get_dataset_path(db::Database, entry::DatasetEntry; kwargs...)
    return get_dataset_path(entry, db.datasets_folder; kwargs...)
end

function get_dataset_path(name::String; kwargs...)
    db = get_default_database()
    return get_dataset_path(db, name; kwargs...)
end


"""
Build a URI string from the metadata fields.
"""
function build_uri(meta::DatasetEntry)
    uri = meta.uri !== "" ? meta.uri : ""
    if uri == ""
        uri = "$(meta.scheme)://$(meta.host)"
        if meta.path !== ""
            uri *= "/$(strip(meta.path, '/'))"
        end
        if meta.version !== ""
            uri *= "#$(meta.version)"
        end
    end
    return uri
end

function guess_file_format(entry::DatasetEntry)
    base, ext = splitext(rstrip(entry.path, '/'))
    if ext == ".gz"
        base, ext2 = splitext(base)
        if ext2 == ".tar"
            ext = ext2 * ext  # Combine extensions if needed
        end
    end
    if ext in KNOWN_EXTENSIONS
        return lstrip(ext, '.')
    else
        return ""
    end
end

function init_dataset_entry(;
    downloads::Vector{String}=Vector{String}(),
    ref::String="",
    kwargs...)

    entry = DatasetEntry(; kwargs...)

    if length(downloads) > 0
        warning("The `downloads` field is deprecated. Use `uri` instead.")

        if (entry.uri !== "")
            error("Cannot provide both uri and downloads")
        end

        if length(downloads) > 1
            error("Only one download URL is supported at the moment. Got: $(length(downloads))")
        end

        entry.uri = downloads[1] # Use the first download URL as the URI
    end

    if (entry.uri !== "")
        parsed = parse_uri_metadata(entry.uri)
        entry.host = parsed.host !== "" ? parsed.host : entry.host
        entry.path = parsed.path !== "" ? parsed.path : entry.path
        entry.scheme = parsed.scheme !== "" ? parsed.scheme : entry.scheme
        entry.format = parsed.format !== "" ? parsed.format : entry.format
        entry.version = parsed.version !== "" ? parsed.version : (entry.version !== "" ? entry.version : ref)
    else
        entry.uri = build_uri(entry)
    end

    if (entry.format == "")
        entry.format = guess_file_format(entry)
    else
        entry.format = lstrip(entry.format, '.')
    end

    entry.extract = entry.extract && (entry.format in COMPRESSED_FORMATS)

    entry.key = entry.key !== "" ? entry.key : get_dataset_key(entry)

    return entry
end


function is_a_git_repo(entry::DatasetEntry)

    segments = split(strip(entry.path, '/'), '/')

    # the path needs to have at least two segments
    if length(segments) < 2 || isempty(segments[1]) || isempty(segments[2])
        return false
    end

    app = split(entry.host, ".")[1]

    known_git_hosts = Set([
        # Popular public Git hosts besides gitlab
        "github.com",
        "bitbucket.org",
        "codeberg.org",
        "gitea.com",
        "sourcehut.org",
        "git.savannah.gnu.org",
        "git.kernel.org",

        # CI/CD Git hosting platforms
        "dev.azure.com"
    ])

    if entry.host in known_git_hosts || app == "gitlab"
        return true
    else
        return joinpath(entry.host, entry.path)
    end

end


function _maybe_persist_database(db::Database, persist::Bool=true)
    if persist && db.datasets_toml != ""
        info("""Write database to $(length(db.datasets_toml) > 60 ? "..."  : "")$(db.datasets_toml[max(end-60, 1):end])""")
        write(db, db.datasets_toml)
    end
end


function update_entry(db::Database, oldname::String, oldentry::DatasetEntry, newname::String, newentry::DatasetEntry;
    overwrite::Bool=false, persist::Bool=true)

    # check the dataset is the same, in a broad sense (elimiate false positives as much as possible)
    if (oldentry.key != newentry.key
        && oldentry.uri != newentry.uri
        && oldentry.version != newentry.version
        && oldname != newname)
        error("At least one the name or any of the following fields must match to update: key, uri")
    end

    if (oldentry == newentry && oldname == newname)
        info("Dataset entry [$newname] already exists.")
        return (oldname => oldentry)
    end

    # verify checksums before proceeding
    verify_checksum(db, oldentry; persist=false)
    verify_checksum(db, newentry; persist=false)

    if (oldentry == newentry)
        if (! overwrite)
            error("Dataset entry already exists with name $oldname. Pass `overwrite=true` to update with new name $newname.")
        else
            warn("Rename $(oldname) => $(newname)")
            delete!(db.datasets, oldname)  # Remove the existing entry if overwriting
            db.datasets[newname] = newentry  # No change here
            _maybe_persist_database(db, persist)
            return (newname => newentry)
        end
    end

    # we have oldentry != newentry
    message = "Possible duplicate found $oldname =>\n$oldentry"

    # check dataset path on disk
    existing_datapath = get_dataset_path(oldentry, db.datasets_folder)
    new_datapath = get_dataset_path(newentry, db.datasets_folder)
    if (existing_datapath != new_datapath && (isfile(existing_datapath) | isdir(existing_datapath)))
        if (isfile(new_datapath) | isdir(new_datapath))
            message *= "\n\nBoth old and new datasets exist on disk at:"
            message *= "\n    $existing_datapath SHA-256: $(oldentry.sha256)"
            message *= "\n    $new_datapath SHA-256: $(newentry.sha256)"
        else
            message *= "\nExisting dataset found at"
            message *= "\n    $existing_datapath\n."
        end
        message *= "\n\nCleanup manually if needed."
        message *= "Note you may explicitly specify the keys to point to a dataset, e.g."
        message *= "\n    key=\"$(oldentry.key)\""
        message *= "\n    key=\"$(newentry.key)\""
    end

    if (overwrite)
        warn("$message\n\nOverwriting with new entry $newname =>\n$newentry")
        if (haskey(db.datasets, oldname))
            delete!(db.datasets, oldname)
        end
        db.datasets[newname] = newentry
        _maybe_persist_database(db, persist)
        return (newname => newentry)
    else
        error("$message\n\nPlease manually remove the old entry or set `overwrite=true` to update with dataset $newname =>\n$newentry or pass `check_duplicate=false` to register nonetheless")
    end

end


"""
    register_dataset([db::Database], uri::String; name::String="", overwrite::Bool=false, persist::Bool=true,
        check_duplicate::Bool=true, version::String="", branch::String="", doi::String="",
        aliases::Vector{String}=String[], key::String="", sha256::String="", skip_checksum::Bool=false,
        skip_download::Bool=false, extract::Bool=false, format::String="") -> Pair{String, DatasetEntry}

Register a dataset in the database, without downloading it.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- If `name` is not provided, it is inferred from the URI or dataset entry.
- All keyword arguments (except for internal fields) correspond to fields in `DatasetEntry`.
- Duplicate entries are checked by default; set `check_duplicate=false` to disable.
- If an entry with the same name or key exists, it is updated or overwritten according to the `overwrite` flag.

# Returns
A pair `(name => entry)` where `entry` is the registered `DatasetEntry`.
"""
function register_dataset(db::Database, uri::String="" ;
    name::String="",
    overwrite::Bool=false,
    persist::Bool=true,
    check_duplicate::Bool=true,
    kwargs...
    )

    entry = init_dataset_entry(; uri=uri, kwargs...)

    if (name == "")
        if is_a_git_repo(entry)
            name = join(split(strip(entry.path, '/'), '/')[1:2], '/')
        else
            name = strip(entry.key)
        end
        name = splitext(name)[1]
    end

    # search by key
    if check_duplicate
        existing_entry = search_dataset(db, entry.key, raise=false) # return nothing if not found
    else
        existing_entry = nothing
    end

    if (existing_entry !== nothing)
        return update_entry(db, existing_entry[1], existing_entry[2], name, entry; overwrite=overwrite, persist=persist)

    elseif haskey(db.datasets, name) && check_duplicate
        return update_entry(db, name, db.datasets[name], name, entry; overwrite=overwrite, persist=persist)
    end

    db.datasets[name] = entry

    if persist && db.datasets_toml != ""
        # If the database is set to persist, write it to disk
        write(db, db.datasets_toml)
    end

    return (name => entry)
end

function get_extract_path(path::String)
    for format in COMPRESSED_FORMATS
        if endswith(path, ".$format")
            return path[1:end-length(format)-1]  # Remove the format suffix
        end
        if occursin("?format=$format", path)
            return rstrip(replace(path, "?format=$format", "?"), '?')  # Remove the format query parameter
        end
    end
    return path * ".d"  # Default extraction path
end

function extract_file(download_path, download_dir, format)
    if format == "zip"
        run(`unzip -o $download_path -d $download_dir`)
    elseif format == "tar.gz"
        run(`tar -xzf $download_path -C $download_dir`)
    elseif format == "tar"
        run(`tar -xf $download_path -C $download_dir`)
    else
        error("Unknown format: $format")
    end
end

function list_alternative_keys(dataset::DatasetEntry)
    alternatives = String[]
    if hasfield(typeof(dataset), :aliases)
        for alias in dataset.aliases
            push!(alternatives, alias)
        end
    end
    if dataset.doi !== ""
        push!(alternatives, dataset.doi)
    end
    push!(alternatives, dataset.key)
    push!(alternatives, dataset.path)
    strip_ext = name -> split(name, '.')[1]  # Split by '.' and take the first part (e.g. a.tar.gz -> a)
    if "/" in dataset.path
        # If the path contains a '/', we can also use the last segment as an alternative key
        alternatives = push!(alternatives, strip_ext(split(dataset.path, `/`)[end]))
    end
    return alternatives
end

function list_dataset_keys(db::Database; alt=true, flat=false)
    entries = []
    for (name, dataset) in pairs(get_datasets(db))
        push!(entries, [name])
        if alt
            for key in list_alternative_keys(dataset)
                push!(entries[end], key)
            end
        end
    end
    if flat
        entries = cat(entries..., dims=1)
    end
    return entries
end

function repr_datasets(db::Database; alt=true)
    lines = [alt ? "Datasets including aliases:" : "Datasets:"]
    for keys in list_dataset_keys(db; alt=alt)
        push!(lines, "- " * join(keys, " | "))
    end
    return join(lines, "\n")
end

function print_dataset_keys(db::Database; alt=true)
    println(repr_datasets(db; alt=alt))
end


"""
    search_datasets([db::Database], name::String; alt=true, partial=false) -> Vector{Pair{String, DatasetEntry}}

Search for datasets in the database by name or alternative keys, returning all matches as a vector of `(name => entry)` pairs.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- The search is **case-insensitive** and proceeds in the following order:

1. Exact match on dataset name (the main key in the database).
2. Exact match on alternative keys (if `alt=true`): any value in `aliases`, `doi`, `key`, or `path`.
3. Partial match on dataset name (if `partial=true`).
4. Partial match on alternative keys (if `alt=true` and `partial=true`).

All matches found in the above order are returned.

# Arguments
- `db::Database` (optional): The database to search in.
- `name::String`: The name, alias, DOI, key, or path of the dataset.
- `alt::Bool`: Whether to search alternative keys (default: `true`).
- `partial::Bool`: Whether to allow partial (substring) matches (default: `false`).

# Returns
A vector of `(name => entry)` pairs for all matching datasets.
"""
function search_datasets(db::Database, name::String ; alt=true, partial=false)
    datasets = get_datasets(db)
    matches = []

    in_results = (key -> key in Set(e[1] for e in matches))

    # first check for exact matches in the keys
    for (key, dataset) in pairs(datasets)
        if lowercase(key) == lowercase(name) && !in_results(key)
            push!(matches, key => dataset)
        end
    end

    # then check for exact matches in the alternative keys
    for (key, dataset) in pairs(datasets)
        if alt && lowercase(name) in map(lowercase, list_alternative_keys(dataset)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end

    # repeat the steps above for partial matches
    for (key, dataset) in pairs(datasets)
        if partial && occursin(lowercase(name), lowercase(key)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end

    for (key, dataset) in pairs(datasets)
        if alt && partial && any(x -> occursin(lowercase(name), lowercase(x)), list_alternative_keys(dataset)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end

    return matches
end


"""
    search_dataset([db::Database], name::String; raise=true, alt=true, partial=false) -> Tuple{String, DatasetEntry}

Search for a dataset by name or alternative keys in the database, returning the first match as a tuple `(name, entry)`.

- The search logic and field priority are the same as in [`search_datasets`](@ref search_datasets).
- If no match is found and `raise=true` (default), an error is thrown. If `raise=false`, returns `nothing`.
- If multiple matches are found, an error is thrown (or a warning if `raise=false`).

# Arguments
- `db::Database` (optional): The database to search in.
- `name::String`: The name, alias, DOI, key, or path of the dataset.
- `raise::Bool`: Whether to throw an error if no match are found, or a warning if multiple matches are found (default: `true`).
- `alt::Bool`: Whether to search alternative keys (default: `true`).
- `partial::Bool`: Whether to allow partial (substring) matches (default: `false`).

# Returns
A tuple `(name, entry)` where `entry` is the found `DatasetEntry`.

# Note
You can also access a dataset entry directly by name using indexing syntax:
```julia
entry = db["dataset_name"]
```
This is equivalent to `search_dataset(db, "dataset_name")[2]`.
"""
function search_dataset(db::Database, name::String; raise=true, kwargs...)
    results = search_datasets(db, name; kwargs...)
    if length(results) == 0
        if raise
            error("""No dataset found for: `$name`.
            Available datasets: $(join(keys(get_datasets(db)), ", "))
            $(repr_datasets(db))
            """)
        else
            return nothing
        end
    elseif (length(results) > 1)
        if raise
            message = "Multiple datasets found for $name:\n- $(join([join(list_alternative_keys(x), " | ") for (name,x) in results], "\n- "))"
            warn(message)
        end
    end
    return results[1]
end

function verify_checksum(db:: Database, dataset::DatasetEntry; persist::Bool=true, extract::Union{Nothing, Bool}=nothing)

    if (extract !== nothing && extract != dataset.extract)
        warn("dataset.extract=$(dataset.extract) but required extract=$extract. Skip verifying checksum.")
        return
    end

    local_path = get_dataset_path(db, dataset)

    if db.skip_checksum || dataset.skip_checksum
        return true  # No SHA-256 checksum required, skip check
    end

    if (!isfile(local_path) && !isdir(local_path))
        return true  # File or directory does not exist, skip check
    end

    if (isdir(local_path) && db.skip_checksum_folders)
        return true  # Skip SHA-256 check for folders if configured
    end

    checksum = sha256_path(local_path)

    if dataset.sha256 == ""
        dataset.sha256 = checksum
        _maybe_persist_database(db, persist)  # Persist the updated dataset entry
        return true  # No SHA-256 checksum provided, simply update
    end

    if dataset.sha256 != checksum
        message = "Checksum mismatch for dataset at $local_path. Expected: $(dataset.sha256), got: $checksum. Possible resolutions:"
        message *= "\n- remove the file"
        message *= "\n- reset the `sha256` field"
        message *= "\n- use a different `key`"
        message *= "\n- remove Entry checksum checks (`dataset.skip_checksum = true`)"
        message *= "\n- remove Database checksum checks (`db.skip_checksum = true`)"
        error(message)
    end

end


function _download_dataset(dataset::DatasetEntry, download_path::String)

    mkpath(dirname(download_path))

    scheme = dataset.scheme

    if scheme in ("ssh", "sshfs")
        # TODO: check the case we're already running on host
        if typeof(dataset.host) != String
            error("SSH scheme requires a host string. Got: $(typeof(dataset.host))")
        end
        target_host = dataset.host
        local_hostname = gethostname()
        if (target_host == local_hostname || split(target_host, ".")[1] == local_hostname)
            scheme = "file"
        end
    end

    if (scheme in ("git", "ssh+git") || (scheme == "https" && endswith(dataset.path, ".git")))
        # repo_url = occursin("@", host) ? "$host:$path" : "git@$host:$path"
        repo_url = dataset.uri
        if dataset.branch !== ""
            run(`git clone --depth 1 --branch $(dataset.branch) $repo_url $download_path`)
        else
            run(`git clone --depth 1 $repo_url $download_path`)
        end

    elseif scheme in ("ssh", "sshfs", "rsync")
        run(`rsync -arvzL $(dataset.host):$(dataset.path) $(dirname(download_path))/`)

    elseif scheme == "file"
        if (dataset.path != download_path)
            run(`rsync -arvzL  $(dataset.path) $(dirname(download_path))/`)
        end

    else
        Downloads.download(dataset.uri, download_path)
    end

end


"""
    download_dataset([db::Database], name::String; extract::Union{Nothing,Bool}=nothing, kwargs...) -> String
    download_dataset([db::Database], entry::DatasetEntry; extract::Union{Nothing,Bool}=nothing) -> String
    download_dataset(name::String; extract::Union{Nothing,Bool}=nothing, kwargs...) -> String

Download a dataset by name or entry, and return the local path.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- You can provide either the dataset name or a `DatasetEntry` object.
- If the dataset is already present, it is not downloaded again.
- If `extract=true`, the dataset is extracted after download (if applicable).
- Checksum verification is performed unless disabled.

# Returns
The local path as a `String`.
"""
function download_dataset(db::Database, dataset::DatasetEntry; extract::Union{Nothing,Bool}=nothing)

    if (dataset.skip_download)
        info("Skipping download for dataset: $(dataset.uri) (skip_download=true)")
        return get_dataset_path(dataset, db.datasets_folder; extract=extract)
    end

    local_path = get_dataset_path(dataset, db.datasets_folder; extract=extract)
    download_path = get_dataset_path(dataset, db.datasets_folder; extract=false)

    if isfile(local_path) || isdir(local_path)
        info("Dataset already exists at: $local_path")
        verify_checksum(db, dataset; extract=extract)
        return local_path
    end

    if ! (isfile(download_path) || isdir(download_path))
        info("Downloading dataset: $(dataset.uri) to $download_path")
        _download_dataset(dataset, download_path)
    else
        info("Dataset already exists at: $download_path")
    end

    if (dataset.extract)
        info("Extracting dataset to: $local_path")
        extract_file(download_path, local_path, dataset.format)
    end

    verify_checksum(db, dataset; extract=extract)

    return local_path
end

"""
    download_datasets([db::Database], names::Union{Nothing,Vector{<:Any}}=nothing; kwargs...) -> Nothing
    download_datasets(names::Union{Nothing,Vector{<:Any}}=nothing; kwargs...) -> Nothing

Download multiple datasets by name.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- If `names` is `nothing`, all datasets in the database are downloaded.
- Each dataset is downloaded using [`download_dataset`](@ref), with the same keyword arguments.
- If a dataset is already present, it is not downloaded again.

# Arguments
- `db::Database` (optional): The database to use.
- `names::Union{Nothing,Vector{<:Any}}`: List of dataset names to download. If `nothing`, downloads all datasets.
- `kwargs...`: Additional keyword arguments passed to [`download_dataset`](@ref).

# Returns
Nothing.
"""
function download_dataset(db::Database, name::String; extract=nothing, kwargs...)
    datasets = get_datasets(db)
    if !haskey(datasets, name)
        (idx, dataset) = search_dataset(db, name; kwargs...)
    else
        dataset = datasets[name]
    end
    return download_dataset(db, dataset; extract=extract)
end


function download_datasets(db::Database, names::Union{Nothing,Vector{<:Any}}=nothing; kwargs...)
    datasets = get_datasets(db)
    if names === nothing
        names = keys(datasets)
    end
    for name in names
        download_dataset(db, name; kwargs...)
    end
end

function get_default_database()
    db = Database()
    if db.datasets_toml != ""
        info("""Using database: $(length(db.datasets_toml) > 60 ? "..." : "")$(db.datasets_toml[max(end-60, 1):end])""")
    else
        error("Please activate a julia environment or pass a Database instance explicity.")
    end
    return db
end

function download_dataset(name::String; kwargs...)
    db = get_default_database()
    return download_dataset(db, name; kwargs...)
end

function download_datasets(names=nothing; kwargs...)
    db = get_default_database()
    return download_datasets(db, names; kwargs...)
end

function register_dataset(uri=String; kwargs...)
    db = get_default_database()
    return register_dataset(db, uri; kwargs...)
end


function register_datasets(db::Database, datasets::Dict; kwargs...)
    for (i, (name, info_)) in enumerate(pairs(datasets))
        info = Dict(Symbol(k) => v for (k, v) in info_)
        persist_on_last_iteration = i == length(datasets)
        register_dataset(db; name=name, persist=persist_on_last_iteration, info..., kwargs...)
    end
end

function register_datasets_toml(db::Database, datasets_toml ; kwargs...)
    config = TOML.parsefile(datasets_toml)
    register_datasets(db, config; kwargs...)
end


function register_datasets(db::Database, datasets_toml::String; kwargs...)
    ext = splitext(datasets_toml)[2]
    if ext == ".toml"
        register_datasets_toml(db, datasets_toml; kwargs...)
    else
        error("Only toml file type supported. Got: $ext")
    end
end

function get_default_toml()
    if isfile(DEFAULT_DATASETS_TOML_PATH)
        return DEFAULT_DATASETS_TOML_PATH
    end

    for envvar in ["DATAMANIFEST_TOML", "DATASETS_TOML"]
        if envvar in keys(ENV) && ENV[envvar] != ""
            env_toml = ENV[envvar]
            if ! isfile(env_toml)
                warn("Environment variable $envvar points to a non-existing file: $env_toml.")
            end
            return env_toml
        end
    end

    if Base.current_project() !== nothing && Base.current_project() == Base.active_project()
        root = abspath(dirname(Base.current_project()))
        currentdefault = joinpath(root, "Datasets.toml")
        alternatives = [
            joinpath(root, "DataManifest.toml"),
            joinpath(root, "datasets.toml")
        ]
        if !isfile(currentdefault)
            for alt in alternatives
                if isfile(alt)
                    currentdefault = alt
                    return alt
                end
            end
            # supports legacy datasets.toml files
            return legacy
        end
        return currentdefault
    else
        warn("The project is not activated. Cannot infer default datasets_toml path. In-memory database will be used.")
        return ""
    end
end


"""Reading from file (legacy function --> now done by Database constructor)"""
function read_dataset(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

"""
    add([db::Database], uri::String; name::String="", overwrite::Bool=false, persist::Bool=true,
        check_duplicate::Bool=true, skip_download::Bool=false, version::String="", branch::String="",
        doi::String="", aliases::Vector{String}=String[], key::String="", sha256::String="",
        skip_checksum::Bool=false, extract::Bool=false, format::String="") -> Pair{String, DatasetEntry}

Add a dataset to the database, downloading it if necessary.

- If `db` is not provided, the default database is used (requires an activated Julia project).
- If `name` is not provided, it is inferred from the URI or dataset entry.
- All keyword arguments (except for internal fields) correspond to fields in `DatasetEntry`.
- If `skip_download` is `false` (default), the dataset will be downloaded after registration.

# Arguments
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

# Returns
A pair `(name => entry)` where `entry` is the registered `DatasetEntry`.
"""
function add(db::Database, uri::String ; skip_download::Bool=false, kwargs...)
    (name, entry) = register_dataset(db, uri; kwargs...)
    if ! skip_download
        download_dataset(db, entry)
    end
    return (name => entry)
end


function add(uri::String=""; kwargs...)
    db = get_default_database()
    return add(db, uri; kwargs...)
end

add_dataset = add # Alias for export

end # module
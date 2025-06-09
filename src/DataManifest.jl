module DataManifest

using TOML
using URIParser
import Downloads
import Base: write, read

export add
export get_dataset_path
export Database, DatasetEntry
export register_dataset, register_datasets
export search_datasets, search_dataset
export download_dataset, download_datasets
export set_datasets_folder, set_datasets, get_datasets_folder, get_datasets
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export repr_short, string_short
export write

XDG_CACHE_HOME = get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
DEFAULT_DATASETS_FOLDER_PATH = joinpath(XDG_CACHE_HOME, "Datasets")
DEFAULT_DATASETS_TOML_PATH = ""
COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]
HIDE_STRUCT_FIELDS = [:host, :path, :scheme]

@kwdef mutable struct DatasetEntry
    uri::Union{String,Nothing} = nothing
    host::Union{String,Nothing} = nothing
    path::Union{String,Nothing} = nothing
    scheme::Union{String,Nothing} = nothing
    version::Union{String,Nothing} = nothing
    branch::Union{String,Nothing} = nothing # for git repositories
    doi::Union{String,Nothing} = nothing
    aliases::Vector{String} = Vector{String}()
    key::String = "" # Unique key for the dataset, usually the doi or a unique name

end


function Base.:(==)(a::DatasetEntry, b::DatasetEntry)
    if typeof(a) != typeof(b)
        return false
    end
    for field in fieldnames(typeof(a))
        if getfield(a, field) != getfield(b, field)
            return false
        end
    end
    return true
end

function to_dict(info::DatasetEntry)
    output = Dict{String,Union{String,Vector{String}}}()
    for field in fieldnames(typeof(info))
        value = getfield(info, field)
        if (field in HIDE_STRUCT_FIELDS)
            continue
        end
        if (value === nothing || value == [] || value == Dict() || value === "")
            continue
        end
        if (field == :key)
            if value == build_dataset_key(info)
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

mutable struct Database
    datasets::Dict{String,<:DatasetEntry}
    datasets_toml::String
    datasets_folder::String

    function Database(;datasets_toml::String="", datasets_folder::String="", persist::Bool=true, kwargs...)
        if datasets_folder == ""
            datasets_folder = DEFAULT_DATASETS_FOLDER_PATH
        end
        if (datasets_toml == "" && persist)
            datasets_toml = get_default_toml()
        end
        db = new(
            Dict{String,DatasetEntry}(),
            persist ? datasets_toml : "",
            datasets_folder
        )
        if (isfile(datasets_toml))
            register_datasets(db, datasets_toml)
        end
        return db
    end

    function Database(datasets_toml::String, datasets_folder::String=""; kwargs...)
        return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
    end

end

function getIndex(db::Database, name::String)
    return search_dataset(db, name)
end

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
    open(datasets_toml, "w") do io
        TOML.print(io, db; kwargs...)
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

function get_datasets_folder(db::Database, datasets_folder::Union{String,Nothing}=nothing)
    if datasets_folder !== nothing
        return datasets_folder
    end
    return db.datasets_folder
end

function get_datasets_toml(db::Database, datasets_toml::Union{String,Nothing}=nothing)
    if datasets_toml !== nothing
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

    version = get(query, "version", nothing)
    ref = get(query, "ref", nothing)

    return (
        uri=uri,
        scheme=scheme,
        host=host,
        path=path,
        version=fragment !== "" ? fragment : (version !==nothing ? version : ref),
    )

end

"""
Build key for local path naming of a dataset entry, based on scheme, host, path and version.
"""
function build_dataset_key(entry::DatasetEntry)
    clean_path = entry.path !== nothing ? strip(entry.path, '/') : ""

    key = joinpath(entry.host, clean_path)

    if (entry.version !== nothing)
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

function get_dataset_path(entry::DatasetEntry, datasets_folder::Union{String,Nothing}=nothing)
    return joinpath(
        # datasets_folder !== nothing ? datasets_folder : DEFAULT_DATASETS_FOLDER_PATH,
        something(datasets_folder, DEFAULT_DATASETS_FOLDER_PATH),
        entry.key,
    )
end

function get_dataset_path(db::Database, name::String; kwargs...)
    dataset = search_dataset(db, name; kwargs...)
    return get_dataset_path(dataset, db.datasets_folder)
end

function get_dataset_path(db::Database, entry::DatasetEntry; kwargs...)
    return get_dataset_path(entry, db.datasets_folder)
end

"""
Build a URI string from the metadata fields.
"""
function build_uri(meta::DatasetEntry)
    uri = meta.uri !== nothing ? meta.uri : ""
    if uri == ""
        uri = "$(meta.scheme)://$(meta.host)"
        if meta.path !== nothing
            uri *= "/$(strip(meta.path, '/'))"
        end
        if meta.version !== nothing
            uri *= "#$(meta.version)"
        end
    end
    return uri
end

"""
"""
function init_dataset_entry(;
    downloads::Vector{String}=Vector{String}(),
    ref::Union{Nothing,String}=nothing,
    kwargs...)

    entry = DatasetEntry(; kwargs...)

    if length(downloads) > 0
        warning("The `downloads` field is deprecated. Use `uri` instead.")

        if (entry.uri !== nothing)
            error("Cannot provide both uri and downloads")
        end

        if length(downloads) > 1
            error("Only one download URL is supported at the moment. Got: $(length(downloads))")
        end

        entry.uri = downloads[1] # Use the first download URL as the URI
    end

    if (entry.uri !== nothing)
        parsed = parse_uri_metadata(entry.uri)
        entry.host = parsed.host !== nothing ? parsed.host : entry.host
        entry.path = parsed.path !== nothing ? parsed.path : entry.path
        entry.scheme = parsed.scheme !== nothing ? parsed.scheme : entry.scheme
        entry.version = parsed.version !== nothing ? parsed.version : (entry.version !== nothing ? entry.version : ref)
    else
        entry.uri = build_uri(entry)
    end

    entry.key = entry.key !== "" ? entry.key : get_dataset_key(entry)

    return entry
end


function register_dataset(db::Database, uri::Union{String,Nothing}=nothing ;
    name::String="",
    overwrite::Bool=false,
    persist::Bool=true,
    kwargs...
    )

    entry = init_dataset_entry(; uri=uri, kwargs...)

    if (name == "")
        if endswith(entry.path, ".git")
            name = strip(entry.path[1:end-4], '/')
        else
            name = strip(entry.key)
            name = splitext(name)[1]
        end
    end

    datasets = get_datasets(db)
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    datasets[name] = entry

    if persist && db.datasets_toml != ""
        # If the database is set to persist, write it to disk
        write(db, db.datasets_toml)
    end

    return (name => entry)
end

function extract_file(download_path)
    download_dir = dirname(download_path)
    if endswith(download_path, ".zip") || occursin("?format=zip", download_path)
        run(`unzip -o $download_path -d $download_dir`)
    elseif endswith(download_path, ".tar.gz")
        run(`tar -xzf $download_path -C $download_dir`)
    elseif endswith(download_path, ".tar")
        run(`tar -xf $download_path -C $download_dir`)
    else
        error("Unknown file type: $download_path")
    end
end

function list_alternative_keys(dataset::DatasetEntry)
    alternatives = String[]
    if hasfield(typeof(dataset), :aliases)
        for alias in dataset.aliases
            push!(alternatives, alias)
        end
    end
    if dataset.doi !== nothing
        push!(alternatives, dataset.doi)
    end
    push!(alternatives, dataset.key)
    push!(alternatives, dataset.path)
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

function search_datasets(db::Database, name::String ; alt=true, partial=false)
    datasets = get_datasets(db)
    matches = []
    for (key, dataset) in pairs(datasets)
        if lowercase(key) == lowercase(name)
            push!(matches, dataset)
        elseif alt && lowercase(name) in map(lowercase, list_alternative_keys(dataset))
            push!(matches, dataset)
        elseif partial && occursin(lowercase(name), lowercase(key))
            push!(matches, dataset)
        elseif alt && partial && any(x -> occursin(lowercase(name), lowercase(x)), list_alternative_keys(dataset))
            push!(matches, dataset)
        end
    end
    return matches
end

function search_dataset(db::Database, name::String; check_unique=true, raise=true, kwargs...)
    results = search_datasets(db, name; kwargs...)
    if length(results) == 0
        error("""No dataset found for: `$name`.
        Available datasets: $(join(keys(get_datasets(db)), ", "))
        $(repr_datasets(db))
        """)
    elseif (check_unique && length(results) > 1)
        message = "Multiple datasets found for $name:\n- $(join([join(list_alternative_keys(x), " | ") for x in results], "\n- "))"
        if raise
            error(message)
        else
            warn(message)
        end
    end
    return results[1]
end

"Fetch dataset"
function download_dataset(db::Database, dataset::DatasetEntry; extract=true)

    local_path = get_dataset_path(dataset, db.datasets_folder)

    if isfile(local_path) || isdir(local_path)
        println("Dataset already exists at: $local_path")
        return local_path
    end

    mkpath(dirname(local_path))

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
        if dataset.branch !== nothing
            run(`git clone --depth 1 --branch $(dataset.branch) $repo_url $local_path`)
        else
            run(`git clone --depth 1 $repo_url $local_path`)
        end

    elseif scheme in ("ssh", "sshfs", "rsync")
        run(`rsync -arvzL $(dataset.host):$(dataset.path) $(dirname(local_path))/`)

    elseif scheme == "file"
        if (dataset.path != local_path)
            run(`rsync -arvzL  $(dataset.path) $(dirname(local_path))/`)
        end

    else
        Downloads.download(dataset.uri, local_path)
    end

    if (extract && any(endswith(local_path, ext) for ext in COMPRESSED_FORMATS))
        extract_file(local_path)
    end

    return local_path
end

"""Download a dataset by name, searching in alternative fields if necessary.
"""
function download_dataset(db::Database, name::String; extract=true, kwargs...)
    datasets = get_datasets(db)
    if !haskey(datasets, name)
        dataset = search_dataset(db, name; kwargs...)
    else
        dataset = datasets[name]
    end
    return download_dataset(db, dataset; extract=extract)
end


function download_datasets(db::Database, names=nothing; kwargs...)
    datasets = get_datasets(db)
    if names === nothing
        names = keys(datasets)
    end
    for name in names
        download_dataset(db, name; kwargs...)
    end
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

    if Base.current_project() !== nothing && Base.current_project() == Base.active_project()
        return joinpath(dirname(Base.current_project()), "datasets.toml")
    else
        println("Warning: the project is not activated. Cannot infer default datasets_toml path. In-memory database will be used.")
        return ""
    end
end


"""Reading from file (legacy function --> now done by Database constructor)"""
function read(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

"""
Add a dataset to the database, downloading it if necessary.
If `name` is not provided, it will be inferred from the uri or dataset entries
"""
function add(db::Database, uri::Union{String,Nothing}=nothing ; download=true, kwargs...)
    (name, entry) = register_dataset(db, uri; kwargs...)
    if download
        download_dataset(db, entry)
    end
    return (name => entry)
end


end # module
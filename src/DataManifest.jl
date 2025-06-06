module DataManifest

using TOML
using URIParser
import Downloads
import Base: write, read

export get_dataset_path
export Database, DatasetEntry
export register_dataset, register_datasets
export search_datasets, search_dataset
export download_dataset, download_datasets
export set_datasets_path, set_datasets, get_datasets_path, get_datasets
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export repr_short, string_short
export write

XDG_CACHE_HOME = get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
DEFAULT_DATASETS_PATH = joinpath(XDG_CACHE_HOME, "Datasets")
COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]

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

function to_dict(info::DatasetEntry; folder=true)
    output = Dict{String,Union{String,Vector{String}}}()
    for field in fieldnames(typeof(info))
        value = getfield(info, field)
        if folder && field == :folder
            continue
        end
        if value !== nothing && value != [] && value != Dict() && value != ""
            output[String(field)] = value
        end
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

@kwdef struct Database
    datasets::Dict{String,<:DatasetEntry} = Dict{String,DatasetEntry}()
    datasets_path::String = DEFAULT_DATASETS_PATH
end

function Base.:(==)(db1::Database, db2::Database)
    return db1.datasets == db2.datasets && db1.datasets_path == db2.datasets_path
end

function to_dict(db::Database; kwargs...)
    return Dict(key => to_dict(entry; kwargs...) for (key, entry) in pairs(db.datasets))
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
    print(io, "datasets_path: $(db.datasets_path)")
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
    print(io, "  datasets_path=$(repr(db.datasets_path))\n)")
end

function TOML.print(io::IO, db::Database; folder=false, kwargs...)
    return TOML.print(io, to_dict(db; folder=folder); kwargs...)
end

function TOML.print(db::Database; folder=false, kwargs...)
    return TOML.print(to_dict(db; folder=folder); kwargs...)
end

function write(db::Database, filepath::String; kwargs...)
    open(filepath, "w") do io
        TOML.print(io, db; kwargs...)
    end
end

"""Accessor functions for back-compatibility
"""
function set_datasets_path(db::Database, path::String)
    db.datasets_path = path
end

function set_datasets(db::Database, datasets::Dict{String,<:DatasetEntry})
    db.datasets = datasets
end

function get_datasets_path(db::Database, datasets_path::Union{String,Nothing}=nothing)
    if datasets_path !== nothing
        return datasets_path
    end
    return db.datasets_path
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
Return local path for dataset entry, based on scheme, host, path and version.
"""
function get_dataset_key(entry::DatasetEntry)

    if entry.key !== ""
        return entry.key
    end

    clean_path = entry.path !== nothing ? strip(entry.path, '/') : ""

    # if entry.doi !== nothing
    #     key = joinpath(entry.doi, basename(clean_path))
    #     # key = joinpath(entry.doi)
    # elseif entry.scheme == "git" || occursin("git@", entry.uri)
    #     key = joinpath(clean_path)
    # else
    #     key = joinpath(entry.host, clean_path)
    # end
    key = joinpath(entry.host, clean_path)

    if (entry.version !== nothing)
        key = key * "#$(entry.version)"
    end

    return strip(key, '/')
end

function get_dataset_path(entry::DatasetEntry, datasets_path::Union{String,Nothing}=nothing)
    return joinpath(
        # datasets_path !== nothing ? datasets_path : DEFAULT_DATASETS_PATH,
        something(datasets_path, DEFAULT_DATASETS_PATH),
        entry.key,
    )
end

function get_dataset_path(db::Database, name::String; kwargs...)
    dataset = search_dataset(db, name; kwargs...)
    return get_dataset_path(dataset, db.datasets_path)
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
    kwargs...
    )

    entry = init_dataset_entry(; uri=uri, kwargs...)

    if (name == "")
        name = strip(entry.path, '/')
        name = splitext(name)[1]
    end

    datasets = get_datasets(db)
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    datasets[name] = entry
    return datasets[name]
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

"Fetch data based on parsed fields"
function download_dataset(db::Database, name::String; extract=true, kwargs...)
    datasets = get_datasets(db)
    if ! haskey(datasets, name)
        dataset = search_dataset(db, name; kwargs...)
    end
    dataset = datasets[name]
    local_path = get_dataset_path(dataset, db.datasets_path)

    if isfile(local_path) || isdir(local_path)
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

    if scheme in ("git", "ssh+git")
        # repo_url = occursin("@", host) ? "$host:$path" : "git@$host:$path"
        repo_url = dataset.uri
        if dataset.branch !== nothing
            run(`git clone --depth 1 --branch $(dataset.branch) $repo_url $local_path`)
        else
            run(`git clone --depth 1 $repo_url $local_path`)
        end

    elseif scheme in ("http", "https")
        Downloads.download(dataset.uri, local_path)

    elseif scheme in ("ssh", "sshfs")
        run(`rsync -arvzL $(dataset.host):$(dataset.path) $(dirname(local_path))/`)

    elseif scheme == "file"
        if (dataset.path != local_path)
            run(`rsync -arvzL  $(dataset.path) $(dirname(local_path))/`)
        end
    else
        error("Unsupported scheme: $scheme")
    end

    if (extract && any(endswith(local_path, ext) for ext in COMPRESSED_FORMATS))
        extract_file(local_path)
    end

    return local_path
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
    for (name, info_) in pairs(datasets)
        info = Dict(Symbol(k) => v for (k, v) in info_)
        register_dataset(db; name=name, info..., kwargs...)
    end
end

function register_datasets_toml(db::Database, filepath; kwargs...)
    config = TOML.parsefile(filepath)
    register_datasets(db, config; kwargs...)
end


function register_datasets(db::Database, filepath::String; kwargs...)
    ext = splitext(filepath)[2]
    if ext == ".toml"
        register_datasets_toml(db, filepath; kwargs...)
    else
        error("Only toml file type supported. Got: $ext")
    end
end


"""Reading from file"""
function Database(filepath::String, datasets_path::Union{String,Nothing}=nothing)
    if datasets_path === nothing || datasets_path == ""
        datasets_path = DEFAULT_DATASETS_PATH
    end
    db = Database(datasets_path=datasets_path)
    register_datasets(db, filepath)
    return db
end


function read(filepath::String, datasets_path::Union{String,Nothing}=nothing; kwargs...)
    return Database(filepath, datasets_path; kwargs...)
end


end # module
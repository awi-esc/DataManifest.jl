module Datasets

import TOML
import Downloads

export Database, DatasetEntry, RepositoryEntry, AbstractEntry
export register_dataset, register_repository, register_datasets
export search_datasets, search_dataset, get_dataset_folder
export download_dataset, download_datasets
export write_datasets_toml
export set_datasets_path, set_datasets, get_datasets_path, get_datasets
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export repr_short, string_short, read

DEFAULT_DATASETS_PATH = "datasets"

abstract type AbstractEntry end

function Base.:(==)(a::AbstractEntry, b::AbstractEntry)
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

function to_dict(info::AbstractEntry; folder=true)
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
function Base.string(x::AbstractEntry)
    return "$(typeof(x)):\n$(join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))),"\n"))"
end

function Base.show(io::IO, x::AbstractEntry)
    # print(io, "$(typeof(x)):\n", join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))), "\n"))
    print(io, Base.string(x))
end

function string_short(x::AbstractEntry)
    return "$(join((string(v) for (k, v) in pairs(to_dict(x)) if k in ["doi", "remote"]), ", "))"
end

function Base.repr(x::AbstractEntry)
    return "$(typeof(x))($(join(("$k=$(repr(v))" for (k, v) in pairs(to_dict(x))), ", ")))"
end

function repr_short(x::AbstractEntry)
    return "$(typeof(x))($(join(("$k=$(repr(v))" for (k, v) in pairs(to_dict(x)) if k in ["doi", "remote"]), ", "))...)"
end

# # This method controls the representation used by repr(x)
# # and is also the one the REPL uses by default.
function Base.show(io::IO, ::MIME"text/plain", x::AbstractEntry)
    print(io, Base.repr(x))
end

@kwdef struct Database
    datasets::Dict{String,<:AbstractEntry} = Dict{String,AbstractEntry}()
    datasets_path::String = DEFAULT_DATASETS_PATH
end

function Base.:(==)(db1::Database, db2::Database)
    return db1.datasets == db2.datasets && db1.datasets_path == db2.datasets_path
end

function to_dict(db::Database; kwargs...)
    return Dict(key => to_dict(entry; kwargs...) for (key, entry) in pairs(db.datasets))
end


@kwdef struct DatasetEntry <: AbstractEntry
    doi::Union{Nothing,String}=nothing
    aliases::Vector{String}=Vector{String}()
    downloads::Vector{String}=Vector{String}()
    version::Union{Nothing,String}=nothing
    folder::String=""
end

@kwdef struct RepositoryEntry <: AbstractEntry
    remote::String
    ref::Union{Nothing,String}=nothing
    branch::Union{Nothing,String}=nothing
    aliases::Vector{String}=Vector{String}()
    folder::String=""
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
        print(io, "- $k => $(string_short(v))\n")
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

function write_datasets_toml(db::Database, filepath::String; kwargs...)
    open(filepath, "w") do io
        TOML.print(io, db; kwargs...)
    end
end

"""Accessor functions for back-compatibility
"""
function set_datasets_path(db::Database, path::String)
    db.datasets_path = path
end

function set_datasets(db::Database, datasets::Dict{String,<:AbstractEntry})
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

COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]

function register_dataset(db::Database, name::String=""; doi::Union{Nothing,String}=nothing,
    aliases::Vector{String}=Vector{String}(),
    downloads::Vector{String}=Vector{String}(),
    url::Union{Nothing,String}=nothing,
    version::Union{Nothing,String}=nothing,
    datasets_path=nothing, folder=nothing,
    overwrite::Bool=false)
    if (name == "" && doi !== nothing)
        name = doi
    end
    if name == ""
        error("name or doi must be provided")
    end
    datasets = get_datasets(db)
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    if url !== nothing
        if length(downloads) > 0
            error("Cannot provide both url and downloads")
        end
        downloads = [url]
    end
    if folder === nothing
        datasets_path = get_datasets_path(db, datasets_path)
        folder = joinpath(datasets_path, doi === nothing ? name : doi)
        if version !== nothing
            folder = joinpath(folder, version)
        end
    end
    datasets[name] = DatasetEntry(doi, aliases, downloads, version, folder)
    return datasets[name]
end

function _parse_git_remote(remote::String)
    if startswith(remote, "git@")
        server, group_repo = split(remote[length("git@")+1:end], ":")
    elseif startswith(remote, "https://")
        remote = remote[length("https://")+1:end]
        server = split(remote, "/")[1]
        group_repo = remote[length(server)+2:end]
    else
        error("Unknown remote type: $remote . Expected git@ or https://")
    end
    group, repo = split(group_repo, "/")
    if endswith(repo, ".git")
        repo = repo[1:end-4]
    end
    return Dict("server" => server, "group" => group, "repo" => repo)
end

function register_repository(db::Database, name::String, remote::String;
    datasets_path::Union{String, Nothing}=nothing, folder=nothing,
    ref::Union{String, Nothing}=nothing,
    branch::Union{String, Nothing}=nothing,
    aliases::Vector{String}=Vector{String}(),
    type="git", overwrite::Bool=false)
    if name == ""
        name, _ = splitext(basename(remote))
    end
    datasets = get_datasets(db)
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    if folder === nothing
        datasets_path = get_datasets_path(db, datasets_path)
        parsed = _parse_git_remote(remote)
        folder = joinpath(folder === nothing ? datasets_path : folder, parsed["server"], parsed["group"], parsed["repo"])
        if ref !== nothing
            folder = joinpath(folder, ref)
        elseif branch !== nothing
            folder = joinpath(folder, branch)
        end
    end
    datasets[name] = RepositoryEntry(remote, ref, branch, aliases, folder)
    return datasets[name]
end

function register_repository(db::Database, remote::String; name::String="", kwargs...)
    return register_repository(db, name, remote; kwargs...)
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

function list_alternative_keys(dataset::AbstractEntry)
    alternatives = [ ]
    if hasfield(typeof(dataset), :aliases)
        for alias in dataset.aliases
            push!(alternatives, alias)
        end
    end
    if hasfield(typeof(dataset), :doi)
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

function search_datasets(db::Database, name; alt=true, partial=false)
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

function search_dataset(db::Database, name; check_unique=true, raise=true, kwargs...)
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

function get_dataset_folder(db::Database, name; kwargs...)
    return search_dataset(db, name; kwargs...).folder
end

function download_dataset(db::Database, name; extract=true, kwargs...)
    datasets = get_datasets(db)
    if ! haskey(datasets, name)
        dataset = search_dataset(db, name; kwargs...)
    end
    dataset = datasets[name]
    download_dir = dataset.folder

    if typeof(dataset) == RepositoryEntry
        if !isdir(joinpath(download_dir, ".git"))
            if dataset.branch !== nothing
                run(`git clone -b $(dataset.branch) $(dataset.remote) $download_dir`)
            else
                run(`git clone $(dataset.remote) $download_dir`)
            end
            if dataset.ref !== nothing
                run(`git -C $download_dir reset --hard $(dataset.ref)`)
            end
        end
        return download_dir
    end

    if !isdir(download_dir)
        mkpath(download_dir)
    end
    for url in dataset.downloads
        download_path = joinpath(download_dir, basename(url))
        if !isfile(download_path)
            Downloads.download(url, download_path)
            if (extract && any(endswith(download_path, formats) for formats in COMPRESSED_FORMATS))
                extract_file(download_path)
            end
        end
    end
    return download_dir
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
        if haskey(info, :remote)
            remote = pop!(info, :remote)
            register_repository(db, name, remote; info..., kwargs...)
        else
            register_dataset(db, name; info..., kwargs...)
        end
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

function read(filepath::String; datasets_path::String=DEFAULT_DATASETS_PATH, kwargs...)
    db = Database(datasets_path=datasets_path, datasets=Dict{String,AbstractEntry}())
    register_datasets(db, filepath)
    return db
end

end # module

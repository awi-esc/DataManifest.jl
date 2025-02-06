module Datasets

import TOML
import Downloads

export register_dataset, register_repository, register_datasets
export search_datasets, search_dataset, get_dataset_folder
export download_dataset, download_datasets
export write_datasets_toml
export set_datasets_path, set_datasets, get_datasets_path, get_datasets
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys

const GLOBAL_STATE = Dict(
    "DATASETS" => Dict(),
    "DATASETS_PATH" => "datasets",
    "EXTRACT" => true,
)

"""Set global state variables such as DATASETS and DATASETS_PATH
"""
function set_datasets_path(path::String)
    GLOBAL_STATE["DATASETS_PATH"] = path
end

function set_datasets(datasets::Dict)
    GLOBAL_STATE["DATASETS"] = datasets
end

function get_datasets_path(datasets_path::Union{String,Nothing}=nothing)
    if datasets_path !== nothing
        return datasets_path
    end
    return GLOBAL_STATE["DATASETS_PATH"]
end

function get_datasets(datasets::Union{Dict,Nothing}=nothing)
    if datasets !== nothing
        return datasets
    end
    return GLOBAL_STATE["DATASETS"]
end

COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]

"""Standard Dataset

Metadata
--------
name: name of the dataset
doi: DOI of the dataset (optional)
aliases: list of aliases for the dataset (optional)
downloads: list of download urls (optional)
    Each URL contains the full specification of the data to download, including the version.
url: alias for `downloads = [ url ]` (optional)
    If url is provided, downloads will be set to [url].
version: version of the dataset (optional)
    If version is provided, the dataset will be saved in a version subfolder.
folder: folder to store the dataset (optional)

Other parameters
----------------
datasets_path: path to store the dataset, if different from GLOBAL (optional)
datasets: dictionary of datasets to store the dataset in (optional)
    By default, the dataset is stored in the module-wide DATASETS dictionary.
overwrite: if true, overwrite existing dataset with the same name (optional)
"""
function register_dataset(name::String=""; doi::Union{Nothing,String}=nothing,
    aliases::Vector{String}=Vector{String}(),
    downloads::Vector{String}=Vector{String}(),
    url::Union{Nothing,String}=nothing,
    version::Union{Nothing,String}=nothing,
    datasets_path=nothing, folder=nothing,
    datasets=nothing, overwrite::Bool=false)
    if (name == "" && doi !== nothing)
        name = doi
    end
    if name == ""
        error("name or doi must be provided")
    end
    datasets = get_datasets(datasets)
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
        datasets_path = get_datasets_path(datasets_path)
        folder = joinpath(datasets_path, doi === nothing ? name : doi)
        if version !== nothing
            folder = joinpath(folder, version)
        end
    end
    datasets[name] = Dict(
        "doi" => doi,
        "downloads" => downloads,
        "folder" => folder,
        "version" => version,
    )
    if length(aliases) > 0
        datasets[name]["aliases"] = aliases
    end
    return datasets[name]
end


"""
parse git@github.com:awi-esc/Datasets.git OR https://github.com/awi-esc/Datasets.git
as server=github.com, group=awi-esc, repo=Datasets
"""
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

"""Register a git register_repository

This function handles git repositories that are to be cloned.
If a specific version is needed, it is sometimes faster to download
a tarball. In that case you should use download_dataset instead,
with appropriate downloads and extract options.

Metadata
--------
name: name of the dataset
remote: git remote url
ref: git reference {hash, branch, tag} (optional)
    --> if the ref is not included in the default git clone,
    the additional `branch=` option can be provided.
branch: git branch to clone (optional)
aliases: list of aliases for the dataset (optional)

Other parameters
----------------
datasets_path: path to store the dataset, if different from GLOBAL (optional)
datasets: dictionary of datasets to store the dataset in (optional)
    By default, the dataset is stored in the module-wide DATASETS dictionary.
overwrite: if true, overwrite existing dataset with the same name (optional)
"""
function register_repository(name::String, remote::String;
    datasets_path::Union{String, Nothing}=nothing, folder=nothing,
    ref::Union{String, Nothing}=nothing,
    branch::Union{String, Nothing}=nothing,
    aliases::Vector{String}=Vector{String}(),
    type="git", datasets=nothing, overwrite::Bool=false)
    if name == ""
        name, _ = splitext(basename(remote))
    end
    datasets = get_datasets(datasets)
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    if folder === nothing
        datasets_path = get_datasets_path(datasets_path)
        parsed = _parse_git_remote(remote)
        folder = joinpath(folder === nothing ? datasets_path : folder, parsed["server"], parsed["group"], parsed["repo"])
        if ref !== nothing
            folder = joinpath(folder, ref)
        elseif branch !== nothing
            folder = joinpath(folder, branch)
        end
    end
    datasets[name] = Dict(
        "remote" => remote,
        "folder" => folder,
        "type" => type,
        "ref" => ref,
        "branch" => branch,
        "aliases" => length(aliases) > 0 ? aliases : [joinpath(parsed["group"], parsed["repo"]), parsed["repo"]],
    )
    return datasets[name]
end

function register_repository(remote::String; name::String="", kwargs...)
    return register_repository(name, remote; kwargs...)
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

function list_alternative_keys(dataset)
    alternatives = [ ]
    if haskey(dataset, "aliases")
        for alias in dataset["aliases"]
            push!(alternatives, alias)
        end
    end
    if haskey(dataset, "doi")
        push!(alternatives, dataset["doi"])
    end
    return alternatives
end

function list_dataset_keys(datasets=nothing; alt=true, flat=false)
    entries = []
    for (name, dataset) in pairs(get_datasets(datasets))
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

function repr_datasets(datasets=nothing; alt=true)
    lines = [alt ? "Datasets including aliases:" : "Datasets:"]
    for keys in list_dataset_keys(datasets; alt=alt)
        push!(lines, "- " * join(keys, " | "))
    end
    return join(lines, "\n")
end

function print_dataset_keys(datasets=nothing; alt=true)
    println(repr_datasets(datasets; alt=alt))
end


"""Search datasets by name. Compare against (by order of priority)

1) dataset ID (key in DATASETS)
2) "aliases" key
3) "doi" key

Also match DOI or aliases unless alt is false.
If partial is true, also search partial matches are returned.

Returns a list of datasets::Vector{Dict} that match the search criteria.
"""
function search_datasets(name; datasets=nothing, alt=true, partial=false)

    datasets = get_datasets(datasets)

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

"""Like search_datasets, but returns the first result or raises an error if no or multiple datasets are found.
"""
function search_dataset(name; check_unique=true, raise=true, datasets=nothing, kwargs...)
    results = search_datasets(name; datasets=datasets, kwargs...)
    if length(results) == 0
        error("""No dataset found for: `$name`.
        Available datasets: $(join(keys(get_datasets(datasets)), ", "))
        $(repr_datasets(datasets))
        """)
    elseif (check_unique && length(results) > 1)
        message = "Multiple datasets found for $name: $(join([join(list_alternative_keys(x), " | ") for x in results], "\n"))"
        if raise
            error(message)
        else
            warn(message)
        end
    end
    return results[1]
end

"""Get the folder of a dataset by name. See search_dataset for more details on key-word arguments.
"""
function get_dataset_folder(name; kwargs...)
    return search_dataset(name; kwargs...)["folder"]
end

function download_dataset(name; extract=nothing, datasets=nothing, kwargs...)
    datasets = get_datasets(datasets)
    if ! haskey(datasets, name)
        dataset = search_dataset(name; datasets=datasets, kwargs...)
    end
    dataset = datasets[name]
    download_dir = dataset["folder"]

    if get(dataset, "type", nothing) == "git"
        if !isdir(joinpath(download_dir, ".git"))
            if get(dataset, "branch", nothing) !== nothing
                run(`git clone -b $(dataset["branch"]) $(dataset["remote"]) $download_dir`)
            else
                run(`git clone $(dataset["remote"]) $download_dir`)
            end
            if get(dataset, "ref", nothing) !== nothing
                run(`git -C $download_dir reset --hard $(dataset["ref"])`)
            end
        end
        return download_dir
    end

    if !isdir(download_dir)
        mkpath(download_dir)
    end
    for url in dataset["downloads"]
        download_path = joinpath(download_dir, basename(url))
        if !isfile(download_path)
            Downloads.download(url, download_path)
            if (extract === nothing ? GLOBAL_STATE["EXTRACT"] : extract) && any(endswith(download_path, formats) for formats in COMPRESSED_FORMATS)
                extract_file(download_path)
            end
        end
    end
    return download_dir
end

function download_datasets(names=nothing; datasets=nothing, kwargs...)
    datasets = get_datasets(datasets)
    if names === nothing
        names = keys(datasets)
    end
    for name in names
        download_dataset(name; datasets=datasets, kwargs...)
    end
end

function register_datasets(datasets::Dict; kwargs...)
    for (name, info_) in pairs(datasets)
        info = Dict(Symbol(k) => v for (k, v) in info_)
        if haskey(info, :remote)
            remote = pop!(info, :remote)
            register_repository(name, remote; info..., kwargs...)
        else
            register_dataset(name; info..., kwargs...)
        end
    end
end

function register_datasets_toml(filepath; kwargs...)
    config = TOML.parsefile(filepath)
    register_datasets(config; kwargs...)
end

function _clean_datasets(datasets::Dict)
    datasets_clean = Dict()
    for (name, info) in pairs(datasets)
        datasets_clean[name] = Dict()
        for (key, value) in pairs(info)
            if (key == "folder")
                continue
            end
            if value !== nothing && value !== [] && value !== Dict() && value !== ""
                datasets_clean[name][key] = value
            end
        end
    end
    return datasets_clean
end

function write_datasets_toml(filepath, datasets::Union{Nothing,Dict}=nothing)
    datasets = get_datasets(datasets)
    datasets_clean = _clean_datasets(datasets)
    open(filepath, "w") do io
        TOML.print(io, datasets_clean)
    end
end

function register_datasets(filepath::String; kwargs...)
    ext = splitext(filepath)[2]
    if ext == ".toml"
        register_datasets_toml(filepath; kwargs...)
    else
        error("Only toml file type supported. Got: $ext")
    end
end

end # module
module Datasets

import TOML
import Downloads

export DATASETS_PATH, DATASETS, register_dataset, register_repository, register_datasets
export search_datasets, search_dataset, get_dataset_folder
export download_dataset, download_datasets
export write_datasets_toml

DATASETS_PATH = "datasets"
DATASETS = Dict()
COMPRESSED_FORMATS = ["zip", "tar.gz", "tar"]
EXTRACT = true

function register_dataset(name::String=""; doi::Union{Nothing,String}=nothing,
    aliases::Vector{String}=Vector{String}(),
    downloads::Vector{String}=Vector{String}(),
    datasets_path=nothing, folder=nothing,
    datasets=DATASETS, overwrite::Bool=false)
    if (name == "" && doi !== nothing)
        name = doi
    end
    if name == ""
        error("name or doi must be provided")
    end
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    if folder === nothing
        if datasets_path === nothing
            datasets_path = DATASETS_PATH
        end
        folder = joinpath(datasets_path, doi === nothing ? name : doi)
    end
    datasets[name] = Dict(
        "doi" => doi,
        "downloads" => downloads,
        "folder" => folder,
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


function register_repository(name::String, remote::String;
    datasets_path::Union{String, Nothing}=nothing, folder=nothing,
    type="git", datasets=DATASETS, overwrite::Bool=false)
    if name == ""
        name, _ = splitext(basename(remote))
    end
    if haskey(datasets, name) && !overwrite
        error("Dataset $name already exists. Set overwrite=true to overwrite.")
    end
    if folder === nothing
        if datasets_path === nothing
            datasets_path = DATASETS_PATH
        end
        parsed = _parse_git_remote(remote)
        folder = joinpath(folder === nothing ? datasets_path : folder, parsed["server"], parsed["group"], parsed["repo"])
    end
    datasets[name] = Dict(
        "remote" => remote,
        "folder" => folder,
        "type" => type,
        "aliases" => [joinpath(parsed["group"], parsed["repo"]), parsed["repo"]],
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

"""Search datasets by name. Compare against (by order of priority)

1) dataset ID (key in DATASETS)
2) "aliases" key
3) "doi" key

If exact is true, only exact matches are returned, otherwise partial matches are also considered.

Returns a list of datasets::Vector{Dict} that match the search criteria.
"""
function search_datasets(name; datasets=DATASETS, exact=false)

    exact_results = []
    partial_results = []

    # first check exact matches in keys
    if haskey(datasets, name)
        push!(exact_results, datasets[name])
    end

    # then check exact matches in alias or doi
    for (key, dataset) in pairs(datasets)
        if (haskey(dataset, "aliases") && (name in dataset["aliases"]))
            push!(exact_results, dataset)
        elseif haskey(dataset, "doi") && dataset["doi"] == name
            push!(exact_results, dataset)
        end
    end

    if exact
        return exact_results
    end

    # then check partial matches in keys
    for key in keys(datasets)
        if name != key && occursin(name, key)
            push!(partial_results, datasets[key])
        end
    end

    # then check partial matches in alias
    for (key, dataset) in pairs(datasets)
        if haskey(dataset, "aliases") && any(x -> occursin(name, x), dataset["aliases"])
            push!(partial_results, dataset)
        elseif haskey(dataset, "doi") && name != dataset["doi"] && occursin(name, dataset["doi"])
            push!(partial_results, dataset)
        end
    end

    return unique(vcat(exact_results, partial_results))
end

"""Like search_datasets, but returns the first result or raises an error if no or multiple datasets are found.
"""
function search_dataset(name; datasets=DATASETS, exact=false, check_unique=false, raise=true)
    results = search_datasets(name; datasets=datasets, exact=exact)
    if length(results) == 0
        error("No dataset found for $name")
    elseif (check_unique && length(results) > 1)
        message = "Multiple datasets found for $name: $(join([get(x, "doi", x) for x in results], ", "))"
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

function download_dataset(name; extract=nothing, datasets=DATASETS)
    if ! haskey(datasets, name)
        dataset = search_dataset(name, exact=true)
    end
    dataset = datasets[name]
    download_dir = dataset["folder"]

    if haskey(dataset, "type")
        if dataset["type"] == "git"
            if !isdir(joinpath(download_dir, ".git"))
                run(`git clone $(dataset["remote"]) $download_dir`)
            end
            return download_dir
        end
    end

    if !isdir(download_dir)
        mkpath(download_dir)
    end
    for url in dataset["downloads"]
        download_path = joinpath(download_dir, basename(url))
        if !isfile(download_path)
            Downloads.download(url, download_path)
            if (extract === nothing ? EXTRACT : extract) && any(endswith(download_path, formats) for formats in COMPRESSED_FORMATS)
                extract_file(download_path)
            end
        end
    end
    return download_dir
end

function download_datasets(names=nothing; kwargs...)
    if names === nothing
        names = keys(DATASETS)
    end
    for name in names
        download_dataset(name; kwargs...)
    end
end

function register_datasets(datasets::Dict; kwargs...)
    for (name, info) in pairs(datasets)
        if haskey(info, "remote")
            register_repository(name, info["remote"]; folder=get(info, "folder", nothing), type=get(info, "type", "git"), kwargs...)
        else
            register_dataset(name; doi=info["doi"], downloads=info["downloads"], folder=get(info, "folder", nothing), kwargs...)
        end
    end
end

function register_datasets_toml(filepath; kwargs...)
    config = TOML.parsefile(filepath)
    register_datasets(config; kwargs...)
end

function _clean_datasets(datasets::Dict=DATASETS)
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

function write_datasets_toml(filepath, datasets::Dict=DATASETS)
    datasets_clean = _clean_datasets(datasets)
    open(filepath, "w") do io
        TOML.print(io, datasets_clean)
    end
end

function register_datasets(filepath::String; datasets_path::Union{Nothing,String}=nothing, kwargs...)
    ext = splitext(filepath)[2]
    if ext == ".toml"
        register_datasets_toml(filepath; datasets_path=datasets_path, kwargs...)
    else
        error("Only toml file type supported. Got: $ext")
    end
end

end # module
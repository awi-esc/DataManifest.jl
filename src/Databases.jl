# Databases: types, path/URI, registry. Single module to limit linkage.
module Databases

using TOML
using URIs
using ..Config: info, warn, sha256_path, get_extract_path, get_default_toml, DEFAULT_DATASETS_FOLDER_PATH,
    COMPRESSED_FORMATS, HIDE_STRUCT_FIELDS, project_root_from_paths

# ----- Types (DatasetEntry, Database) -----
Base.@kwdef mutable struct DatasetEntry
    uri::String = ""
    host::String = ""
    path::String = ""
    scheme::String = ""
    version::String = ""
    branch::String = ""
    doi::String = ""
    aliases::Vector{String} = Vector{String}()
    key::String = ""
    sha256::String = ""
    skip_checksum::Bool = false
    skip_download::Bool = false
    extract::Bool = false
    format::String = ""
    shell::String = ""
    julia::String = ""
    julia_modules::Vector{String} = String[]
    loader::String = ""
    requires::Vector{String} = String[]
end

function Base.:(==)(a::DatasetEntry, b::DatasetEntry)
    if typeof(a) != typeof(b)
        return false
    end
    for field in fieldnames(typeof(a))
        if (field in [:sha256, :skip_checksum])
            continue
        end
        if getfield(a, field) != getfield(b, field)
            return false
        end
    end
    return true
end

function build_dataset_key(entry::DatasetEntry, path::String="")
    clean_path = strip(path == "" ? entry.path : path, '/')
    key = joinpath(entry.host, clean_path)
    if (entry.version !== "")
        key = key * "#$(entry.version)"
    end
    return strip(key, '/')
end

"""
Infer file format from the dataset key (e.g. \"data/out.csv\" -> \"csv\", \"archive.tar.gz\" -> \"tar.gz\").
Strips any version # fragment before taking the extension.
"""
function guess_file_format(entry::DatasetEntry)
    key = rstrip(entry.key, '/')
    # Trim version suffix (e.g. host/path#v1.0 -> host/path)
    if occursin('#', key)
        key = split(key, '#'; limit=2)[1]
    end
    isempty(key) && return ""
    base, ext = splitext(key)
    if ext == ".gz"
        base, ext2 = splitext(base)
        if ext2 == ".tar"
            ext = ext2 * ext
        end
    end
    return lstrip(ext, '.')
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
                continue
            end
        end
        if (field == :format)
            if value == guess_file_format(entry)
                continue
            end
        end
        output[String(field)] = value
    end
    return output
end

function Base.string(x::DatasetEntry)
    return "$(typeof(x)):\n$(join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))),"\n"))"
end

function Base.show(io::IO, x::DatasetEntry)
    print(io, Base.string(x))
end

function string_short(x::DatasetEntry)
    return x.key
end

function trimstring(s::String, n::Int; path=true)
    if length(s) <= n
        return s
    end
    if !path
        return s[1:n] * "..."
    end
    while length(s) > n
        parts = splitpath(s)
        if length(parts) <= 1
            return s
        end
        s = joinpath(parts[1:end-1])
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

function Base.show(io::IO, ::MIME"text/plain", x::DatasetEntry)
    print(io, Base.repr(x))
end

mutable struct Database
    datasets::Dict{String,<:DatasetEntry}
    datasets_toml::String
    datasets_folder::String
    skip_checksum::Bool
    skip_checksum_folders::Bool
    loaders::Dict{String,String}
    loaders_julia_modules::Vector{String}
    loaders_julia_includes::Vector{String}
    loader_cache::Dict{String,Function}
    loader_context_module::Union{Module,Nothing}

    function Database(datasets::Dict{String,<:DatasetEntry},
            datasets_toml::String,
            datasets_folder::String,
            skip_checksum::Bool,
            skip_checksum_folders::Bool,
            loaders::Dict{String,String},
            loaders_julia_modules::Vector{String},
            loaders_julia_includes::Vector{String},
            loader_cache::Dict{String,Function},
            loader_context_module::Union{Module,Nothing})
        new(datasets, datasets_toml, datasets_folder, skip_checksum, skip_checksum_folders,
            loaders, loaders_julia_modules, loaders_julia_includes, loader_cache, loader_context_module)
    end
end

function Base.:(==)(db1::Database, db2::Database)
    return db1.datasets == db2.datasets && db1.datasets_folder == db2.datasets_folder &&
           db1.datasets_toml == db2.datasets_toml && db1.loaders == db2.loaders &&
           db1.loaders_julia_modules == db2.loaders_julia_modules &&
           db1.loaders_julia_includes == db2.loaders_julia_includes
end

function to_dict(db::Database; kwargs...)
    loaders_table = Dict{String,Any}("julia_modules" => db.loaders_julia_modules, "julia_includes" => db.loaders_julia_includes)
    for (n, c) in pairs(db.loaders)
        loaders_table[n] = c
    end
    result = Dict{String,Any}("_LOADERS" => loaders_table)
    for (key, entry) in pairs(db.datasets)
        result[key] = to_dict(entry; kwargs...)
    end
    return result
end

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

function TOML.print(io::IO, db::Database; sorted=true, kwargs...)
    return TOML.print(io, to_dict(db); sorted=sorted, kwargs...)
end

function TOML.print(db::Database; sorted=true, kwargs...)
    return TOML.print(to_dict(db); sorted=sorted, kwargs...)
end

function write(db::Database, datasets_toml::String; kwargs...)
    toml_string = sprint(TOML.print, db; kwargs...)
    if (toml_string === nothing)
        error("Failed to convert Database to TOML string.")
    end
    open(datasets_toml, "w") do io
        Base.write(io, toml_string)
    end
end

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

# ----- PathUri -----
function parse_uri_metadata(uri::String)
    if startswith(uri, "git@")
        scheme = "git"
        uri = replace(uri, ":" => "/")
        uri = replace(uri, "git@" => "git://")
    end
    parsed = URI(uri)
    host = String(parsed.host)
    scheme = String(parsed.scheme)
    path = rstrip(String(parsed.path), '/')
    fragment = String(parsed.fragment)
    query = queryparams(parsed)
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

function get_dataset_key(entry::DatasetEntry)
    if entry.key !== ""
        return entry.key
    end
    return build_dataset_key(entry)
end

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

function get_dataset_path(db::Database, entry::DatasetEntry; kwargs...)
    return get_dataset_path(entry, get_datasets_folder(db); kwargs...)
end

function get_dataset_path(db::Database, name::String; extract=nothing, kwargs...)
    (name, dataset) = search_dataset(db, name; kwargs...)
    return get_dataset_path(dataset, db.datasets_folder; extract=extract)
end

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

function init_dataset_entry(;
    downloads::Vector{String}=Vector{String}(),
    ref::String="",
    kwargs...)
    entry = DatasetEntry(; kwargs...)
    if length(downloads) > 0
        warn("The `downloads` field is deprecated. Use `uri` instead.")
        if (entry.uri !== "")
            error("Cannot provide both uri and downloads")
        end
        if length(downloads) > 1
            error("Only one download URL is supported at the moment. Got: $(length(downloads))")
        end
        entry.uri = downloads[1]
    end
    if (entry.uri !== "")
        parsed = parse_uri_metadata(entry.uri)
        entry.host = parsed.host !== "" ? parsed.host : entry.host
        entry.path = parsed.path !== "" ? parsed.path : entry.path
        entry.scheme = parsed.scheme !== "" ? parsed.scheme : entry.scheme
        entry.format = parsed.format !== "" ? parsed.format : entry.format
        entry.version = parsed.version !== "" ? parsed.version : (entry.version !== "" ? entry.version : ref)
    else
        if entry.shell == "" && entry.julia == ""
            entry.uri = build_uri(entry)
        end
    end
    entry.key = entry.key !== "" ? entry.key : get_dataset_key(entry)
    if (entry.format == "")
        entry.format = guess_file_format(entry)
    else
        entry.format = lstrip(entry.format, '.')
    end
    entry.extract = entry.extract && (entry.format in COMPRESSED_FORMATS)
    if !isempty(entry.requires)
        entry.requires = String[String(r) for r in entry.requires]
    end
    if !isempty(entry.julia_modules)
        entry.julia_modules = String[String(m) for m in entry.julia_modules]
    end
    return entry
end

function is_a_git_repo(entry::DatasetEntry)
    segments = split(strip(entry.path, '/'), '/')
    if length(segments) < 2 || isempty(segments[1]) || isempty(segments[2])
        return false
    end
    app = split(entry.host, ".")[1]
    known_git_hosts = Set(["github.com", "bitbucket.org", "codeberg.org", "gitea.com", "sourcehut.org", "git.savannah.gnu.org", "git.kernel.org", "dev.azure.com"])
    if entry.host in known_git_hosts || app == "gitlab"
        return true
    else
        return false
    end
end

# ----- Registry -----
function _maybe_persist_database(db::Database, persist::Bool=true)
    if persist && db.datasets_toml != ""
        info("""Write database to $(length(db.datasets_toml) > 60 ? "..."  : "")$(db.datasets_toml[max(end-60, 1):end])""")
        write(db, db.datasets_toml)
    end
end

function verify_checksum(db::Database, dataset::DatasetEntry; persist::Bool=true, extract::Union{Nothing, Bool}=nothing)
    if (extract !== nothing && extract != dataset.extract)
        warn("dataset.extract=$(dataset.extract) but required extract=$extract. Skip verifying checksum.")
        return
    end
    local_path = get_dataset_path(db, dataset)
    if db.skip_checksum || dataset.skip_checksum
        return true
    end
    if (!isfile(local_path) && !isdir(local_path))
        return true
    end
    if (isdir(local_path) && db.skip_checksum_folders)
        return true
    end
    checksum = sha256_path(local_path)
    if dataset.sha256 == ""
        dataset.sha256 = checksum
        _maybe_persist_database(db, persist)
        return true
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

function update_entry(db::Database, oldname::String, oldentry::DatasetEntry, newname::String, newentry::DatasetEntry;
    overwrite::Bool=false, persist::Bool=true)
    if (oldentry.key != newentry.key && oldentry.uri != newentry.uri && oldentry.version != newentry.version && oldname != newname)
        error("At least one the name or any of the following fields must match to update: key, uri")
    end
    if (oldentry == newentry && oldname == newname)
        info("Dataset entry [$newname] already exists.")
        return (oldname => oldentry)
    end
    verify_checksum(db, oldentry; persist=false)
    verify_checksum(db, newentry; persist=false)
    if (oldentry == newentry)
        if (! overwrite)
            error("Dataset entry already exists with name $oldname. Pass `overwrite=true` to update with new name $newname.")
        else
            warn("Rename $(oldname) => $(newname)")
            delete!(db.datasets, oldname)
            db.datasets[newname] = newentry
            _maybe_persist_database(db, persist)
            return (newname => newentry)
        end
    end
    message = "Possible duplicate found $oldname =>\n$oldentry"
    existing_datapath = get_dataset_path(oldentry, db.datasets_folder)
    new_datapath = get_dataset_path(newentry, db.datasets_folder)
    if (existing_datapath != new_datapath && (isfile(existing_datapath) | isdir(existing_datapath)))
        if (isfile(new_datapath) | isdir(new_datapath))
            message *= "\n\nBoth old and new datasets exist on disk at:"
            message *= "\n    $existing_datapath SHA-256: $(oldentry.sha256)"
            message *= "\n    $new_datapath SHA-256: $(newentry.sha256)"
        else
            message *= "\nExisting dataset found at\n    $existing_datapath\n."
        end
        message *= "\n\nCleanup manually if needed."
        message *= "Note you may explicitly specify the keys to point to a dataset, e.g.\n    key=\"$(oldentry.key)\"\n    key=\"$(newentry.key)\""
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

function register_dataset(db::Database, uri::String="" ;
    name::String="",
    overwrite::Bool=false,
    persist::Bool=true,
    check_duplicate::Bool=true,
    kwargs...)
    entry = init_dataset_entry(; uri=uri, kwargs...)
    if (name == "")
        if is_a_git_repo(entry)
            name = join(split(strip(entry.path, '/'), '/')[1:2], '/')
        else
            name = strip(entry.key)
        end
        name = splitext(name)[1]
    end
    if check_duplicate
        existing_entry = search_dataset(db, entry.key; raise=false)
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
        write(db, db.datasets_toml)
    end
    return (name => entry)
end

function _remove_dataset_from_disk(db::Database, entry::DatasetEntry)
    if entry.skip_download
        return
    end
    download_path = get_dataset_path(entry, db.datasets_folder; extract=false)
    if entry.extract
        local_path = get_dataset_path(entry, db.datasets_folder; extract=true)
        if isdir(local_path)
            rm(local_path; force=true, recursive=true)
        end
    end
    if isfile(download_path)
        rm(download_path; force=true)
    elseif isdir(download_path)
        rm(download_path; force=true, recursive=true)
    end
end

function delete_dataset(db::Database, name::String; keep_cache::Bool=false, persist::Bool=true)
    (resolved_name, entry) = search_dataset(db, name)
    if !keep_cache
        _remove_dataset_from_disk(db, entry)
    end
    delete!(db.datasets, resolved_name)
    if persist && db.datasets_toml != ""
        write(db, db.datasets_toml)
    end
    return nothing
end

function extract_file(download_path, download_dir, format)
    mkpath(download_dir)
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
    if is_a_git_repo(dataset)
        repo_name = split(strip(dataset.path, '/'), '/')[2]
        push!(alternatives, repo_name)
    end
    unique_names = []
    for alt in alternatives
        if !isempty(alt) && !(alt in unique_names)
            push!(unique_names, alt)
        end
    end
    return unique_names
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
    in_results = (key -> key in Set(e[1] for e in matches))
    for (key, dataset) in pairs(datasets)
        if lowercase(key) == lowercase(name) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
    for (key, dataset) in pairs(datasets)
        if alt && lowercase(name) in map(lowercase, list_alternative_keys(dataset)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
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

Base.getindex(db::Database, name::String) = search_dataset(db, name)[2]

function register_loaders(db::Database; loaders=nothing, julia_modules=nothing, julia_includes=nothing, persist::Bool=true)
    if loaders !== nothing
        db.loaders = Dict{String,String}(String(k) => (v isa String ? v : repr(v)) for (k, v) in pairs(loaders))
    end
    if julia_modules !== nothing
        db.loaders_julia_modules = String.(julia_modules)
    end
    if julia_includes !== nothing
        db.loaders_julia_includes = String.(julia_includes)
    end
    empty!(db.loader_cache)
    db.loader_context_module = nothing
    pipemod = parentmodule(@__MODULE__).PipeLines
    for name in keys(db.loaders)
        pipemod._get_loader_function(db, name)
    end
    if persist && db.datasets_toml != ""
        write(db, db.datasets_toml)
    end
end

function register_datasets(db::Database, datasets::Dict; kwargs...)
    L = get(datasets, "_LOADERS", get(datasets, "_loaders", nothing))
    if L isa Dict
        mods = haskey(L, "julia_modules") && L["julia_modules"] isa Vector ? String.(L["julia_modules"]) : String[]
        incs = haskey(L, "julia_includes") && L["julia_includes"] isa Vector ? String.(L["julia_includes"]) : String[]
        loader_dict = Dict{String,String}(String(k) => (v isa String ? v : repr(v)) for (k, v) in L if k != "julia_modules" && k != "julia_includes")
        register_loaders(db; loaders=loader_dict, julia_modules=mods, julia_includes=incs, persist=false)
    end
    names = [k for k in keys(datasets) if k != "_LOADERS" && k != "_loaders"]
    for (i, name) in enumerate(names)
        info_ = datasets[name]
        info = Dict(Symbol(k) => v for (k, v) in (info_ isa Dict ? info_ : pairs(info_)))
        persist_on_last_iteration = i == length(names)
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

# ----- Database keyword constructor, get_default_database, get_project_root -----
function Database(; datasets_toml::String="", datasets_folder::String="",
    persist::Bool=true, skip_checksum::Bool=false, skip_checksum_folders::Bool=false,
    datasets::Dict{String,<:DatasetEntry}=Dict{String,DatasetEntry}(), kwargs...)
    if datasets_folder == ""
        datasets_folder = DEFAULT_DATASETS_FOLDER_PATH
    end
    if (datasets_toml == "" && persist)
        datasets_toml = get_default_toml()
    end
    toml_path = persist && datasets_toml != "" ? abspath(datasets_toml) : ""
    db = Database(
        datasets,
        toml_path,
        datasets_folder,
        skip_checksum,
        skip_checksum_folders,
        Dict{String,String}(),
        String[],
        String[],
        Dict{String,Function}(),
        nothing,
    )
    if isfile(datasets_toml)
        register_datasets(db, datasets_toml; kwargs...)
    end
    return db
end

function Database(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

function get_project_root(db::Database)::String
    return project_root_from_paths(db.datasets_toml, Base.current_project())
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

function read_dataset(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

function add(db::Database, uri::String ; skip_download::Bool=false, kwargs...)
    (name, entry) = register_dataset(db, uri; kwargs...)
    if ! skip_download
        parentmodule(@__MODULE__).PipeLines.download_dataset(db, entry)
    end
    return (name => entry)
end

# ----- Convenience methods (default database) -----
register_dataset(uri::String; kwargs...) = register_dataset(get_default_database(), uri; kwargs...)
register_dataset(db::Nothing, uri::String; kwargs...) = register_dataset(uri; kwargs...)
delete_dataset(name::String; kwargs...) = delete_dataset(get_default_database(), name; kwargs...)
add(uri::String=""; kwargs...) = add(get_default_database(), uri; kwargs...)
get_dataset_path(name::String; kwargs...) = get_dataset_path(get_default_database(), name; kwargs...)

end # module Databases

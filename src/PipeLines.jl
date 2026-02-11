# PipeLines: download + load pipeline and default loaders. Depends on Databases and Config.
module PipeLines

import Downloads
using ..Config: info, COMPRESSED_FORMATS
using ..Databases: DatasetEntry, Database, get_datasets, get_dataset_path, search_dataset, verify_checksum,
    extract_file, get_project_root, get_default_database
using ..DefaultLoaders: default_loader as builtin_default_loader

_sanitize_ref(ref::String) = replace(replace(ref, '/' => '_'), '.' => '_')

"""
Return dataset names in topological order for download (dependencies first).
"""
function _get_download_order(db::Database, name::String; kwargs...)::Vector{String}
    graph = Dict{String,Vector{String}}()
    seen = Set{String}()

    function collect_deps(n::String)
        n in seen && return
        push!(seen, n)
        (_, entry) = search_dataset(db, n; kwargs...)
        deps = String[]
        for ref in entry.requires
            (dep_name, _) = search_dataset(db, ref; kwargs...)
            push!(deps, dep_name)
            collect_deps(dep_name)
        end
        graph[n] = deps
    end

    collect_deps(name)

    in_degree = Dict(n => length(deps) for (n, deps) in pairs(graph))
    queue = [n for n in keys(graph) if in_degree[n] == 0]
    order = String[]
    while !isempty(queue)
        u = popfirst!(queue)
        push!(order, u)
        for (v, deps) in pairs(graph)
            if u in deps
                in_degree[v] -= 1
                if in_degree[v] == 0
                    push!(queue, v)
                end
            end
        end
    end

    if length(order) != length(graph)
        error("Circular dependency in dataset requires: $name")
    end

    return order
end

function expand_shell_template(template::String, entry::DatasetEntry, download_path::String, project_root::String="";
                               required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                               required_paths_ordered::Vector{String}=String[])::String
    if occursin("\$project_root", template) && project_root == ""
        error("Shell template contains \$project_root but project root could not be determined. " *
              "Use an activated Julia project or a Database with datasets_toml set.")
    end
    result = template
    result = replace(result, "\$download_path" => download_path)
    result = replace(result, "\$project_root" => project_root)
    result = replace(result, "\$uri" => entry.uri)
    result = replace(result, "\$key" => entry.key)
    result = replace(result, "\$version" => entry.version)
    result = replace(result, "\$doi" => entry.doi)
    result = replace(result, "\$format" => entry.format)
    result = replace(result, "\$branch" => entry.branch)
    for (sanitized_ref, path) in pairs(required_paths_by_ref)
        result = replace(result, "\$path_$(sanitized_ref)" => path)
    end
    result = replace(result, "\$requires_paths" => join(required_paths_ordered, " "))
    for (i, path) in enumerate(required_paths_ordered)
        result = replace(result, "\$path_$(i)" => path)
    end
    return result
end

function _run_julia(dataset::DatasetEntry, download_path::String, project_root::String;
                   required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                   required_paths_ordered::Vector{String}=String[])
    mod = Module()
    Core.eval(mod, :(download_path = $download_path))
    Core.eval(mod, :(project_root = $project_root))
    Core.eval(mod, :(entry = $dataset))
    Core.eval(mod, :(required_paths_by_ref = $required_paths_by_ref))
    Core.eval(mod, :(required_paths_ordered = $required_paths_ordered))
    for m in dataset.julia_modules
        Core.eval(mod, :(using $(Symbol(m))))
    end
    run_code() = Base.include_string(mod, dataset.julia, "julia")
    if project_root != ""
        cd(run_code, project_root)
    else
        run_code()
    end
end

function _get_loader_module(db::Database)::Module
    if db.loader_context_module === nothing
        mod = Module()
        base = get_project_root(db)
        if base == "" && db.datasets_toml != ""
            base = dirname(db.datasets_toml)
        end
        if base == ""
            base = pwd()
        end
        for inc in db.loaders_julia_includes
            path = isabspath(inc) ? inc : joinpath(base, inc)
            Base.include(mod, path)
        end
        for m in db.loaders_julia_modules
            Core.eval(mod, :(using $(Symbol(m))))
        end
        # So loader code can call default_loader("nc") etc. to refer to built-in loaders
        Core.eval(mod, Expr(:(=), :default_loader, builtin_default_loader))
        db.loader_context_module = mod
    end
    return db.loader_context_module
end

# Heuristic: string looks like "A[.B.C].func" (module path + function) rather than inline code.
function _is_loader_reference(s::String)
    s = strip(s)
    length(s) < 2 && return false
    # Must contain at least one dot (Module.func)
    occursin('.', s) || return false
    # Must not look like expression code
    occursin(" -> ", s) && return false
    occursin(" => ", s) && return false
    startswith(s, "(") && return false
    occursin(r"\bfunction\s+", s) && return false
    return true
end

# Resolve "A.B.C.func" at runtime: import top-level module A in loader context, then getfield chain.
# Returns the callable or nothing if not a reference / resolution failed.
function _resolve_loader_reference(db::Database, code::String)
    _is_loader_reference(code) || return nothing
    parts = split(code, '.')
    length(parts) < 2 && return nothing
    mod = _get_loader_module(db)
    first_mod = String(parts[1])
    # Import top-level module at runtime (avoids circular deps at precompile time)
    Core.eval(mod, :(using $(Symbol(first_mod))))
    current = getfield(mod, Symbol(first_mod))
    for i in 2:(length(parts) - 1)
        current = getfield(current, Symbol(parts[i]))
    end
    fn = getfield(current, Symbol(parts[end]))
    return fn isa Function ? fn : nothing
end

function _get_loader_function(db::Database, name_or_code::String; cache_key::Union{String,Nothing}=nothing, _alias_chain::Set{String}=Set{String}())
    key = cache_key === nothing ? name_or_code : cache_key
    if haskey(db.loader_cache, key)
        return db.loader_cache[key]
    end
    code = haskey(db.loaders, name_or_code) ? db.loaders[name_or_code] : name_or_code
    # Alias: value is exactly another loader name -> resolve it (with cycle detection)
    if code isa String && haskey(db.loaders, code) && code != name_or_code
        name_or_code in _alias_chain && error("Loader alias cycle involving \"$name_or_code\" and \"$code\".")
        chain = union(_alias_chain, Set([name_or_code]))
        fn = _get_loader_function(db, code; _alias_chain=chain)
        db.loader_cache[key] = fn
        return fn
    end
    # If string looks like "A[.B.C].func", resolve by runtime import + getfield; else compile via include_string
    if code isa String
        fn = _resolve_loader_reference(db, code)
        if fn !== nothing
            db.loader_cache[key] = fn
            return fn
        end
    end
    mod = _get_loader_module(db)
    fn = Base.include_string(mod, code isa String ? code : repr(code), "loader")
    if !(fn isa Function)
        error("loader \"$name_or_code\" did not evaluate to a function, got $(typeof(fn))")
    end
    db.loader_cache[key] = fn
    return fn
end

function _download_dataset(dataset::DatasetEntry, download_path::String; project_root::String="", overwrite::Bool=false,
                          required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                          required_paths_ordered::Vector{String}=String[])

    mkpath(dirname(download_path))

    if dataset.julia !== ""
        _run_julia(dataset, download_path, project_root;
                  required_paths_by_ref=required_paths_by_ref,
                  required_paths_ordered=required_paths_ordered)
        return
    end

    if dataset.shell !== ""
        cmd_expanded = expand_shell_template(dataset.shell, dataset, download_path, project_root;
                                             required_paths_by_ref=required_paths_by_ref,
                                             required_paths_ordered=required_paths_ordered)
        cmd = Cmd(split(cmd_expanded))
        if project_root != ""
            run(setenv(cmd; dir=project_root))
        else
            run(cmd)
        end
        return
    end

    scheme = dataset.scheme

    if scheme in ("ssh", "sshfs")
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
        if overwrite && isdir(download_path)
            rm(download_path; force=true, recursive=true)
        end
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

function _name_for_entry(db::Database, entry::DatasetEntry)::String
    for (n, e) in pairs(db.datasets)
        e === entry && return n
    end
    (name, _) = search_dataset(db, entry.key; raise=true)
    return name
end

function download_dataset(db::Database, dataset::DatasetEntry; extract::Union{Nothing,Bool}=nothing, overwrite::Bool=false, kwargs...)
    name = _name_for_entry(db, dataset)

    reqs = dataset.requires
    if !isempty(reqs)
        order = _get_download_order(db, name; kwargs...)
        for dep_name in order[1:end-1]
            download_dataset(db, dep_name; extract=extract, overwrite=false, kwargs...)
        end
    end

    if (dataset.skip_download)
        info("Skipping download for dataset: $(dataset.uri) (skip_download=true)")
        return get_dataset_path(dataset, db.datasets_folder; extract=extract)
    end

    local_path = get_dataset_path(dataset, db.datasets_folder; extract=extract)
    download_path = get_dataset_path(dataset, db.datasets_folder; extract=false)

    if !overwrite && (isfile(local_path) || isdir(local_path))
        info("Dataset already exists at: $local_path")
        verify_checksum(db, dataset; extract=extract)
        return local_path
    end

    if overwrite || !(isfile(download_path) || isdir(download_path))
        info("Downloading dataset: $(dataset.uri) to $download_path")
        project_root = get_project_root(db)
        req_paths_by_ref = Dict{String,String}()
        req_paths_ordered = String[]
        if !isempty(reqs) && (dataset.shell !== "" || dataset.julia !== "")
            order = _get_download_order(db, name; kwargs...)
            for ref in reqs
                (_, dep_entry) = search_dataset(db, ref; kwargs...)
                path = get_dataset_path(dep_entry, db.datasets_folder; extract=extract !== nothing ? extract : dep_entry.extract)
                req_paths_by_ref[_sanitize_ref(ref)] = path
            end
            for dep_name in order[1:end-1]
                (_, dep_entry) = search_dataset(db, dep_name; kwargs...)
                push!(req_paths_ordered, get_dataset_path(dep_entry, db.datasets_folder; extract=extract !== nothing ? extract : dep_entry.extract))
            end
        end
        _download_dataset(dataset, download_path; project_root=project_root, overwrite=overwrite,
                         required_paths_by_ref=req_paths_by_ref, required_paths_ordered=req_paths_ordered)
    elseif !overwrite
        info("Dataset already exists at: $download_path")
    end

    if (dataset.extract)
        if overwrite && isdir(local_path)
            rm(local_path; force=true, recursive=true)
        end
        info("Extracting dataset to: $local_path")
        extract_file(download_path, local_path, dataset.format)
    end

    verify_checksum(db, dataset; extract=extract)

    return local_path
end

function download_dataset(db::Database, name::String; extract=nothing, overwrite::Bool=false, kwargs...)
    datasets = get_datasets(db)
    if !haskey(datasets, name)
        (_, dataset) = search_dataset(db, name; kwargs...)
    else
        dataset = datasets[name]
    end
    return download_dataset(db, dataset; extract=extract, overwrite=overwrite, kwargs...)
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

# ----- Default loaders (db.loaders then DefaultLoaders) -----
"""
    default_loader(db::Database, format::AbstractString) -> Function

Return a loader function `path -> value` for the given format, when no loader is passed to `load_dataset`.
Resolution: (1) a named loader in `db.loaders` whose `lowercase(name) == lowercase(format)`; (2) else built-in from DefaultLoaders (csv, parquet, nc, dimstack, md, txt, json, yaml, toml); (3) else error.

When evaluating loader code from `_LOADERS` or `entry.loader`, the name `default_loader` is available:
use `default_loader(\"nc\")`, `default_loader(\"dimstack\")`, etc. to refer to the built-in loaders.
E.g. set `nc = "dimstack"` in _LOADERS so .nc uses dimstack by default, and for a specific dataset set
`loader = "default_loader(\\\"nc\\\")"` to use the raw NCDataset loader.
"""
function default_loader(db::Database, format::AbstractString)
    f = lowercase(strip(format))
    if isempty(f)
        error("No loader provided and dataset format is empty. Pass a loader function, e.g. loader = path -> read(path, String).")
    end
    for name in keys(db.loaders)
        lowercase(name) == f && return _get_loader_function(db, name)
    end
    return builtin_default_loader(format)
end

# World-age errors are MethodError with world != typemax(UInt); "no matching method" uses typemax(UInt).
function _is_world_age_error(e)
    return e isa MethodError && e.world != typemax(UInt)
end

function _call_loader(fn::Function, path::String, entry::DatasetEntry)
    try
        return fn(path, entry)
    catch e
        if _is_world_age_error(e)
            try
                return Base.invokelatest(fn, path, entry)
            catch e2
                if e2 isa MethodError
                    return Base.invokelatest(fn, path)
                end
                rethrow(e2)
            end
        end
        if e isa MethodError
            try
                return fn(path)
            catch
                rethrow(e)
            end
        end
        rethrow(e)
    end
end

function load_dataset(db::Database, name::String; loader=nothing, kwargs...)
    (_, entry) = search_dataset(db, name; kwargs...)
    return load_dataset(db, entry; loader=loader, kwargs...)
end

function load_dataset(db::Database, entry::DatasetEntry; loader=nothing, kwargs...)
    path = download_dataset(db, entry; kwargs...)
    if loader !== nothing && loader != ""
        if loader isa String
            if !haskey(db.loaders, loader)
                error("loader must be a callable or a loader name defined in _LOADERS (got unknown name \"$loader\")")
            end
            loader = _get_loader_function(db, loader)
        end
        return _call_loader(loader, path, entry)
    elseif entry.loader != ""
        fn = _get_loader_function(db, entry.loader)
        return _call_loader(fn, path, entry)
    else
        # For extracted archives, path is a directory; no single-file format to load
        format = (entry.extract && entry.format in COMPRESSED_FORMATS) ? "" : entry.format
        return _call_loader(default_loader(db, format), path, entry)
    end
end

# ----- Convenience (default database) -----
download_dataset(name::String; kwargs...) = download_dataset(get_default_database(), name; kwargs...)
download_dataset(db::Nothing, name::String; kwargs...) = download_dataset(name; kwargs...)
download_datasets(names::Union{Nothing,Vector{<:Any}}=nothing; kwargs...) = download_datasets(get_default_database(), names; kwargs...)
download_datasets(db::Nothing, names::Union{Nothing,Vector{<:Any}}=nothing; kwargs...) = download_datasets(names; kwargs...)
load_dataset(name::String; kwargs...) = load_dataset(get_default_database(), name; kwargs...)
load_dataset(db::Nothing, name::String; kwargs...) = load_dataset(name; kwargs...)

end # module PipeLines

# PipeLines: download + load pipeline and default loaders. Depends on Databases and Config.
module PipeLines

import Downloads
using FileWatching: Pidfile
using FileWatching.Pidfile: mkpidlock, trymkpidlock
using ..Config: info, COMPRESSED_FORMATS
using ..Databases: DatasetEntry, Database, get_datasets, get_dataset_path, resolve_existing_path,
    resolve_from_pools, search_dataset, verify_checksum, record_dataset_state,
    extract_file, get_project_root, get_default_database, parse_uri_metadata, _parse_binding,
    storage_layers
using ..Storage: tmp_path, lock_path, marker_path, is_complete, config_layers,
    lock_stale_age, DEFAULT_LOCK_STALE_AGE
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

# ----- Parameterized-binding `$var` substitution -----
# A `{ ref, args, kwargs }` binding may embed `$var` placeholders in any string
# value. The variable set mirrors `expand_shell_template`: a rung-specific path
# var (`$download_path` for fetchers, `$path` for loaders) plus the dataset
# metadata vars. Substitution is applied to every string element, recursively
# into nested arrays/sub-tables; non-string scalars pass through unchanged.
function _binding_subst_pairs(dataset::DatasetEntry, primary::Pair{String,String}, project_root::String)
    return Pair{String,String}[
        primary,
        "\$project_root" => project_root,
        "\$uri" => dataset.uri,
        "\$key" => dataset.key,
        "\$version" => dataset.version,
        "\$doi" => dataset.doi,
        "\$format" => dataset.format,
        "\$branch" => dataset.branch,
    ]
end

_subst_binding_value(v::AbstractString, subs::Vector{Pair{String,String}}) = begin
    s = String(v)
    for (k, val) in subs
        s = replace(s, k => val)
    end
    s
end
_subst_binding_value(v::AbstractVector, subs::Vector{Pair{String,String}}) =
    Any[_subst_binding_value(x, subs) for x in v]
_subst_binding_value(v::AbstractDict, subs::Vector{Pair{String,String}}) =
    Dict{String,Any}(String(k) => _subst_binding_value(x, subs) for (k, x) in v)
_subst_binding_value(v, ::Vector{Pair{String,String}}) = v

# Turn a (possibly substituted) kwargs Dict into Symbol=>value pairs for splatting.
_kwargs_pairs(kwargs::AbstractDict) = [Symbol(k) => v for (k, v) in kwargs]

function _run_julia(dataset::DatasetEntry, download_path::String, project_root::String;
                   required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                   required_paths_ordered::Vector{String}=String[],
                   loaders_julia_modules::Vector{String}=String[])
    mod = Module()
    Core.eval(mod, :(download_path = $download_path))
    Core.eval(mod, :(project_root = $project_root))
    Core.eval(mod, :(entry = $dataset))
    Core.eval(mod, :(required_paths_by_ref = $required_paths_by_ref))
    Core.eval(mod, :(required_paths_ordered = $required_paths_ordered))
    Core.eval(mod, :(requires = $required_paths_ordered))
    # Same names as shell template so julia code can use $uri, $key, etc. in strings
    Core.eval(mod, :(uri = $(dataset.uri)))
    Core.eval(mod, :(key = $(dataset.key)))
    Core.eval(mod, :(version = $(dataset.version)))
    Core.eval(mod, :(doi = $(dataset.doi)))
    Core.eval(mod, :(format = $(dataset.format)))
    Core.eval(mod, :(branch = $(dataset.branch)))
    # [_LOADERS].julia_modules then entry.julia_modules so entries can use global modules without repeating
    for m in vcat(loaders_julia_modules, dataset.julia_modules)
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

# ----- v1 `module:function` ref resolution -----
# v1 bindings (`_LANG.julia` fetcher/loader and `[_LANG.julia.loaders]`) are
# expressed as `"Module[.Sub]:function"` refs, never inline code. Resolution
# imports the module at runtime into the loader context (so project-local
# packages on the load path are found) and walks via getfield to the function —
# no `include_string` / `eval` of user code, only an import plus field access.
function _resolve_ref(db::Database, ref::String)
    s = strip(ref)
    parts2 = split(s, ':'; limit=2)
    length(parts2) == 2 || error("Invalid binding reference \"$ref\": expected \"Module:function\".")
    modpath = strip(parts2[1])
    fname = strip(parts2[2])
    (isempty(modpath) || isempty(fname)) &&
        error("Invalid binding reference \"$ref\": expected \"Module:function\".")
    mod = _get_loader_module(db)
    parts = split(modpath, '.')
    Core.eval(mod, :(using $(Symbol(String(parts[1])))))
    current = getfield(mod, Symbol(String(parts[1])))
    for i in 2:length(parts)
        current = getfield(current, Symbol(String(parts[i])))
    end
    fn = getfield(current, Symbol(fname))
    fn isa Function || error("Binding reference \"$ref\" did not resolve to a function, got $(typeof(fn)).")
    return fn
end

# Invoke a v1 Julia `fetcher` ref. The resolved function is called with the same
# context the legacy inline path exposed, as keyword args (matching the
# cross-language convention), inside the project root. `invokelatest` avoids
# world-age errors from the runtime `using`.
function _run_julia_ref(db::Database, dataset::DatasetEntry, download_path::String, project_root::String;
                       required_paths_ordered::Vector{String}=String[])
    fn = _resolve_ref(db, dataset.lang_julia_fetcher)
    local call
    if !isempty(dataset.lang_julia_fetcher_args) || !isempty(dataset.lang_julia_fetcher_kwargs)
        # Parameterized binding: substitute `$var` and call `ref(args...; kwargs...)`.
        subs = _binding_subst_pairs(dataset, "\$download_path" => download_path, project_root)
        args = _subst_binding_value(dataset.lang_julia_fetcher_args, subs)
        kwargs = _kwargs_pairs(_subst_binding_value(dataset.lang_julia_fetcher_kwargs, subs))
        call = () -> Base.invokelatest(fn, args...; kwargs...)
    else
        # Bare-string ref: conventional keyword-arg call (unchanged behavior).
        call = () -> Base.invokelatest(fn;
            download_path=download_path, project_root=project_root, entry=dataset,
            uri=dataset.uri, key=dataset.key, version=dataset.version, doi=dataset.doi,
            format=dataset.format, branch=dataset.branch,
            requires_paths=required_paths_ordered)
    end
    if project_root != ""
        cd(call, project_root)
    else
        call()
    end
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

"""
Given a list of URI path strings, return relative paths that preserve enough directory
structure to disambiguate filenames. The common leading directory segments are stripped.
Example: ["/data1/file.nc", "/data2/file.nc"] → ["data1/file.nc", "data2/file.nc"]
"""
# Read a dataset's v1 `[<ds>._LANG.shell].fetcher` template. Shell is not parsed
# into the model (Item 2 kept every foreign `_LANG.<other>` verbatim in `extra`),
# so the fetch ladder reads it from there. Returns "" when absent.
function _lang_shell_fetcher(entry::DatasetEntry)::String
    lang = get(entry.extra, "_LANG", nothing)
    lang isa AbstractDict || return ""
    shell = get(lang, "shell", nothing)
    shell isa AbstractDict || return ""
    f = get(shell, "fetcher", nothing)
    return f isa AbstractString ? String(f) : ""
end

# ----- Language-implicit (bare) fetcher (spec-v3.4/3.6) -----
# A dataset MAY carry a bare `fetcher` binding read as the running tool's own language
# (equivalent to `[<ds>._LANG.julia].fetcher`). Explicit `_LANG.julia.fetcher` wins; a bare
# fetcher is **present** for Julia ⇒ spec-v3.6 fail-loud: it resolves-or-errors and a runtime
# error propagates (never a silent fall-through to the next rung).

# The bare fetcher's `module:function` ref (string or `{ ref … }` table), or "" when absent.
function _bare_fetcher_ref(entry::DatasetEntry)::String
    f = get(entry.extra, "fetcher", nothing)
    f isa AbstractString && return String(f)
    if f isa AbstractDict
        r = get(f, "ref", nothing)
        return r isa AbstractString ? String(r) : ""
    end
    return ""
end

# Resolve + run a bare fetcher `ref` as the own-language fetcher (conventional keyword-arg
# call, like the bare-string `_LANG.julia.fetcher`). Present-for-Julia ⇒ a resolution or
# runtime failure propagates (spec-v3.6 fail-loud).
function _run_bare_fetcher(db::Database, dataset::DatasetEntry, ref::String,
                          download_path::String, project_root::String;
                          required_paths_ordered::Vector{String}=String[])
    fn = _resolve_ref(db, ref)
    call = () -> Base.invokelatest(fn;
        download_path=download_path, project_root=project_root, entry=dataset,
        uri=dataset.uri, key=dataset.key, version=dataset.version, doi=dataset.doi,
        format=dataset.format, branch=dataset.branch, requires_paths=required_paths_ordered)
    project_root != "" ? cd(call, project_root) : call()
    return nothing
end

# The dataset's shell fetcher command (spec-v3.5): the bare, language-agnostic `shell` field,
# else the legacy `[<ds>._LANG.shell].fetcher`. "" when neither is present.
_shell_command(entry::DatasetEntry)::String =
    entry.shell != "" ? entry.shell : _lang_shell_fetcher(entry)

# ----- Cross-language fetch (fetch ladder rung 3): delegate to the peer CLI -----
# The rare case: a dataset's bytes can be produced only by a fetcher defined in another
# language (no own Julia fetcher, no shell fetcher, no `uri`). The Python `datamanifest` is
# the reference peer and aims to cover every language, so we invoke it: it resolves its own
# store (matching ours by default) and materializes the result there, which our
# read-resolution then finds. Falls through to the normal path (→ a clear "no fetcher"
# error) when delegation is disabled, the CLI is absent, or the call fails.

const PEER_CLI = "datamanifest"

# Languages other than julia/shell that declare a `fetcher` for this dataset — i.e. a
# foreign fetcher only the peer CLI can run.
function _foreign_fetcher_langs(entry::DatasetEntry)::Vector{String}
    lang = get(entry.extra, "_LANG", nothing)
    lang isa AbstractDict || return String[]
    out = String[]
    for (k, v) in lang
        ks = String(k)
        (ks == "julia" || ks == "shell") && continue
        v isa AbstractDict && haskey(v, "fetcher") && push!(out, ks)
    end
    return out
end

# Whether to attempt cross-language delegation for this dataset. The optional `delegate`
# field forces it on/off; absent, it defaults on — delegation is the only way to fetch a
# foreign-only dataset, so the alternative is a hard "no fetcher" error.
function _should_delegate(entry::DatasetEntry)::Bool
    d = get(entry.extra, "delegate", nothing)
    return d isa Bool ? d : true
end

# Run `datamanifest download <name>`, pointing the peer at our manifest via
# `DATAMANIFEST_TOML`. The peer writes into the shared store (verifying `sha256`) and exits
# non-zero on failure. Returns true on a zero exit; false when the CLI is absent / no
# manifest on disk / the call fails.
function _delegate_fetch(db::Database, name::AbstractString)::Bool
    (Sys.which(PEER_CLI) === nothing) && return false
    isempty(db.datasets_toml) && return false
    env = copy(ENV)
    env["DATAMANIFEST_TOML"] = abspath(db.datasets_toml)
    try
        info("Cross-language fetch: delegating \"$name\" to the peer CLI (`$PEER_CLI download`)")
        run(setenv(`$PEER_CLI download $name`, env))
        return true
    catch e
        info("Peer-CLI fetch for \"$name\" failed; falling through ($(sprint(showerror, e)))")
        return false
    end
end

# Expand and run a shell fetch template. Shared by the v0 `shell=` field and the
# v1 `_LANG.shell.fetcher` rung so both behave identically.
function _run_shell(template::String, dataset::DatasetEntry, download_path::String, project_root::String;
                   required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                   required_paths_ordered::Vector{String}=String[])
    cmd_expanded = expand_shell_template(template, dataset, download_path, project_root;
                                         required_paths_by_ref=required_paths_by_ref,
                                         required_paths_ordered=required_paths_ordered)
    cmd = Cmd(split(cmd_expanded))
    if project_root != ""
        run(setenv(cmd; dir=project_root))
    else
        run(cmd)
    end
end

function _uri_relative_paths(uris::Vector{String})::Vector{String}
    segments = [filter(!isempty, split(parse_uri_metadata(u).path, '/')) for u in uris]
    # Guard: empty path segments
    if any(isempty, segments)
        return [basename(parse_uri_metadata(u).path) for u in uris]
    end
    # Find how many leading directory segments are common (never consume the filename)
    min_len = minimum(length(s) for s in segments)
    n_common = 0
    for i in 1:(min_len - 1)
        if all(s[i] == segments[1][i] for s in segments)
            n_common = i
        else
            break
        end
    end
    return [joinpath(s[n_common+1:end]...) for s in segments]
end

# --- safe materialization -----------------------------------------------------

# Lock staleness (spec-v5.2/v5.3). The lock holder refreshes the pidfile's mtime every
# `stale_age/2` (the stdlib Pidfile heartbeat), so a live holder's lock age stays near
# zero however long the write takes. A lock is reclaimed as stale once its age exceeds
# `stale_age` AND (its PID is dead on this host, or the age exceeds 5×`stale_age` — a
# holder that missed many consecutive heartbeats on another node). With the default 30s: a
# crashed same-host holder is picked up within ~30s, a cross-host frozen holder after
# ~2.5min. Reclaiming a live holder's lock is safe by construction (staging + atomic
# rename + completion marker): worst case is duplicate work, never a partial entry.
# The age is the config field `lock_stale_age`, resolved on the ordinary ladder
# (`Storage.lock_stale_age`): the composition roots (fetch / produce) resolve it with
# their full project config; the bare default here covers direct `materialize` calls
# (env + cwd-checkout + user config, no manifest layer).

"""
    materialize(write_fn, target; on_locked=:wait, stale_age=lock_stale_age(...),
                skip_if=nothing) -> target

Safely publish a dataset at `target`. `write_fn(tmp)` populates the staging path
`tmp = <target>.tmp` (a file or a directory); on success it is atomically
renamed onto `target` and a completion marker is created (`<target>/.complete`
for a directory, `<target>.complete` for a file). A `<target>.lock` pidfile
(recording `pid host`, mtime-refreshed every `stale_age/2` while held) is held
for the duration and removed afterwards.

When the lock is already held, `on_locked` decides (spec-v5.2):

- `:wait` (default) — block until the holder releases it (or its lock goes
  stale: age beyond `stale_age` with a dead local PID, or beyond 5×`stale_age`
  of missed heartbeats), then proceed. `stale_age` defaults to the spec-v5.3
  config field `lock_stale_age` ([`Storage.lock_stale_age`], default 30s).
- `:fail` — raise immediately (the pre-0.29 behavior).
- `:proceed` — go ahead without exclusivity, staging under a process-private
  `<target>.tmp.<pid>` so concurrent writers never clobber each other's staging;
  the last atomic rename wins.

`skip_if(target)`, when given, is evaluated **after** the lock is acquired: if it
returns `true` the write is skipped entirely and `target` is returned as-is —
the recheck that lets a waiter adopt the entry its peer just published instead
of recomputing it.

A failed or interrupted `write_fn` leaves no marker and no published entry —
only a stray `.tmp` — so the target is still treated as absent on the next load.

For back-compatibility with fetchers that write straight to `target` (e.g. the
`rsync`/`file` schemes, which deposit the source basename into the parent dir),
a `write_fn` that produced `target` directly (and no `tmp`) is accepted as-is.
"""
# Acquire `target`'s `.lock` pidfile per `on_locked`, shared by `materialize` and
# `with_lock`. Returns `(monitor, got)`: `monitor` is the lock handle to `close` later
# (`nothing` only under `:proceed` when the lock could not be taken — i.e. running without
# exclusivity); `got` is whether this call holds the lock. Throws under `:fail` when held.
function _acquire_lock(lock::AbstractString, on_locked::Symbol, stale_age::Real)
    if on_locked === :wait
        # An already-stale lock (a holder that crashed long ago) is reclaimed
        # IMMEDIATELY: the stdlib's blocking path only runs its first staleness check
        # after one full `stale_age` of waiting, so try the non-blocking acquire (which
        # checks and reclaims stale locks up front) before falling back to the wait.
        # Only a lock fresher than `stale_age` — a live holder, or a crash within the
        # last `stale_age` seconds (indistinguishable until the heartbeat is missed) —
        # is actually waited on.
        got = trymkpidlock(lock; stale_age=stale_age)
        monitor = got === false ? mkpidlock(lock; stale_age=stale_age) : got
        return (monitor, true)
    end
    got = trymkpidlock(lock; stale_age=stale_age)
    if got === false
        if on_locked === :fail
            pid, host, _ = Pidfile.parse_pidfile(lock)
            error("Target is locked by another process (pid $pid" *
                  (isempty(host) ? "" : " on $host") * "): $lock")
        end
        return (nothing, false)   # :proceed — no exclusivity
    end
    return (got, true)
end

function materialize(write_fn, target::AbstractString;
                     on_locked::Symbol=:wait,
                     stale_age::Real=lock_stale_age(storage_config=config_layers()),
                     skip_if=nothing)
    on_locked in (:wait, :fail, :proceed) ||
        throw(ArgumentError("materialize: on_locked must be :wait, :fail, or :proceed; got :$on_locked"))
    target = String(target)
    tmp = tmp_path(target)
    lock = lock_path(target)
    dir = dirname(target)
    !isempty(dir) && mkpath(dir)
    monitor, got = _acquire_lock(lock, on_locked, stale_age)
    # :proceed without the lock — stage under a process-private path so concurrent
    # writers never clobber each other's staging; the last atomic rename wins.
    got || (tmp = string(tmp, ".", getpid()))
    try
        # Recheck under the lock: a peer may have just published this very target.
        if skip_if !== nothing && skip_if(target)
            return target
        end
        # Clear any stale staging artifact from a previous interrupted run.
        (isfile(tmp) || isdir(tmp)) && rm(tmp; force=true, recursive=true)
        write_fn(tmp)
        if isfile(tmp) || isdir(tmp)
            mv(tmp, target; force=true)
        elseif !(isfile(target) || isdir(target))
            error("materialize: write function produced neither `$tmp` nor `$target`")
        end
        touch(marker_path(target))
    finally
        monitor === nothing || close(monitor)
    end
    return target
end

"""
    with_lock(f, target; on_locked=:wait, stale_age=lock_stale_age(...), skip_if=nothing)

Run `f()` while holding `target`'s `<target>.lock` pidfile — the same heartbeat-refreshed
lock [`materialize`](@ref) uses, with the same `on_locked`/`stale_age` semantics. Unlike
`materialize`, it performs **no staging, rename, or completion marker**: it is the
consumer-side primitive for serializing arbitrary side-effecting writes that derive
*additional* files into an already-materialised artifact directory (or anything else keyed
by `target`), so the "produce these side-artifacts once, reuse across all peers" contract
is actually serialized rather than racing on check-then-write.

`on_locked` (spec-v5.2):
- `:wait` (default) — block until the holder releases the lock (or it goes stale), then run.
- `:fail` — raise immediately if the lock is held.
- `:proceed` — run without exclusivity if the lock cannot be taken.

`skip_if(target)`, when given, is evaluated **after** the lock is acquired: if it returns
`true`, `f` is **not** run and `with_lock` returns `nothing` — the recheck that lets a waiter
adopt what a peer just produced instead of redoing the work. Otherwise returns `f()`'s value.

The directory holding the lock is created if absent. `f` takes no arguments (it writes into
paths it already knows — typically siblings of `target`).
"""
function with_lock(f, target::AbstractString;
                   on_locked::Symbol=:wait,
                   stale_age::Real=lock_stale_age(storage_config=config_layers()),
                   skip_if=nothing)
    on_locked in (:wait, :fail, :proceed) ||
        throw(ArgumentError("with_lock: on_locked must be :wait, :fail, or :proceed; got :$on_locked"))
    target = String(target)
    lock = lock_path(target)
    dir = dirname(lock)
    !isempty(dir) && mkpath(dir)
    monitor, _ = _acquire_lock(lock, on_locked, stale_age)
    try
        if skip_if !== nothing && skip_if(target)
            return nothing
        end
        return f()
    finally
        monitor === nothing || close(monitor)
    end
end

# Object-store URI schemes (spec-v4.3): "fetch the object, then verify sha256", mechanism
# left to the tool. DataManifest.jl has no native backend, so a download of one errors with a
# pointer to `lazy_access` / delegation (HTTP/HTTPS keep their own dedicated path, not here).
const OBJECT_STORE_SCHEMES = ("s3", "gs", "gcs", "az", "abfs", "abfss", "adl", "gdrive")

function _download_dataset(dataset::DatasetEntry, download_path::String; project_root::String="", overwrite::Bool=false,
                          required_paths_by_ref::Dict{String,String}=Dict{String,String}(),
                          required_paths_ordered::Vector{String}=String[],
                          loaders_julia_modules::Vector{String}=String[],
                          db::Union{Database,Nothing}=nothing)

    # Schema v1 resolves bindings only via `module:function` refs; the inline
    # `julia=`/`Base.include_string` path below is retained for v0/legacy files.
    v1 = db !== nothing && db.schema == 1

    mkpath(dirname(download_path))

    # v1 fetch ladder: own `_LANG.julia.fetcher` → `_LANG.shell.fetcher` → uri →
    # error (delegation is out of scope). The julia/shell rungs return early; the
    # uri rung falls through to the uris/scheme handling below, and the absence of
    # every rung is a clear error.
    if v1
        # rung 1 — own `_LANG.julia.fetcher`, else the bare (language-implicit) `fetcher`.
        if dataset.lang_julia_fetcher != ""
            _run_julia_ref(db, dataset, download_path, project_root;
                          required_paths_ordered=required_paths_ordered)
            return
        end
        bare_fetcher = _bare_fetcher_ref(dataset)
        if bare_fetcher != ""
            # present-for-Julia ⇒ commit to it (resolution/runtime errors propagate).
            _run_bare_fetcher(db, dataset, bare_fetcher, download_path, project_root;
                             required_paths_ordered=required_paths_ordered)
            return
        end
        # rung 2 — the dataset's `shell` command (bare field, else legacy `_LANG.shell`).
        shell_cmd = _shell_command(dataset)
        if shell_cmd != ""
            _run_shell(shell_cmd, dataset, download_path, project_root;
                      required_paths_by_ref=required_paths_by_ref,
                      required_paths_ordered=required_paths_ordered)
            return
        end
        if isempty(dataset.uris) && dataset.uri == ""
            error("No fetcher resolved for dataset \"$(dataset.key)\": no own/bare " *
                  "`fetcher`, no `shell` command, and no `uri`/`uris`.")
        end
    end

    if !isempty(dataset.uris)
        mkpath(download_path)
        rel_paths = _uri_relative_paths(dataset.uris)
        for (uri, rel) in zip(dataset.uris, rel_paths)
            if isempty(rel)
                error("Cannot determine filename from URI: $uri")
            end
            file_path = joinpath(download_path, rel)
            mkpath(dirname(file_path))
            try
                Downloads.download(uri, file_path)
            catch e
                throw(ErrorException(
                    "Automatic download failed for URI $uri.\nOriginal error: " *
                    sprint(showerror, e)))
            end
        end
        return
    end

    if !v1 && dataset.julia !== ""
        _run_julia(dataset, download_path, project_root;
                  required_paths_by_ref=required_paths_by_ref,
                  required_paths_ordered=required_paths_ordered,
                  loaders_julia_modules=loaders_julia_modules)
        return
    end

    if dataset.shell !== ""
        _run_shell(dataset.shell, dataset, download_path, project_root;
                  required_paths_by_ref=required_paths_by_ref,
                  required_paths_ordered=required_paths_ordered)
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

    elseif scheme in OBJECT_STORE_SCHEMES
        # spec-v4.3: object-store schemes mean "fetch the object, then verify sha256", but the
        # mechanism is implementation-defined. DataManifest.jl has no built-in object-store
        # backend; rather than silently skip, error clearly and point to the supported paths.
        error("Object-store URI \"$(dataset.uri)\" (scheme `$(scheme)://`) cannot be fetched " *
              "natively by DataManifest.jl — there is no built-in object-store backend " *
              "(spec-v4.3). Open it in place with `lazy_access = true` plus a loader that reads " *
              "`$(scheme)://` (e.g. an AWSS3 / fsspec-style loader), or delegate the fetch to a " *
              "peer `datamanifest` tool that implements the scheme.")

    else
        try
            Downloads.download(dataset.uri, download_path)
        catch e
            throw(ErrorException(
                "Automatic download failed. Please manually download the file from\n  $(dataset.uri)\nand save it to\n  $download_path\n\nOriginal error: " *
                sprint(showerror, e)))
        end
    end
end

function _name_for_entry(db::Database, entry::DatasetEntry)::String
    for (n, e) in pairs(db.datasets)
        e === entry && return n
    end
    (name, _) = search_dataset(db, entry.key; raise=true)
    return name
end

function _missing_dataset_error(dataset::DatasetEntry, path::String)
    msg = "Dataset file or folder not found at `$path`."
    if !isempty(dataset.uris)
        msg *= " Documented URIs: " * join(("`$u`" for u in dataset.uris), ", ") * "."
    elseif dataset.uri != ""
        msg *= " The documented URI is `$(dataset.uri)`."
    end
    error(msg)
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

    # Lazy / on-the-fly access (spec-v4.3): never download; the `uri` is opened in place by the
    # loader. Nothing local to verify or record.
    if (dataset.lazy_access)
        info("Lazy access (not downloaded): $(dataset.uri)")
        return get_dataset_path(db, dataset; extract=extract)
    end

    if (dataset.skip_download)
        info("Skipping download for dataset: $(dataset.uri) (skip_download=true)")
        path = get_dataset_path(db, dataset; extract=extract)
        if !(isfile(path) || isdir(path))
            _missing_dataset_error(dataset, path)
        end
        return path
    end

    local_path = get_dataset_path(db, dataset; extract=extract)
    download_path = get_dataset_path(db, dataset; extract=false)

    # Read-resolution: reuse an existing copy in any store — including the legacy
    # read-only location (~/.cache/Datasets) — rather than re-downloading to the
    # new write path. New fetches still land in download_path/local_path.
    if !overwrite
        existing = resolve_existing_path(db, dataset; extract=extract)
        if isfile(existing) || isdir(existing)
            info("Dataset already exists at: $existing")
            verify_checksum(db, dataset; extract=extract, skip_if_complete=true)
            record_dataset_state(db, dataset, existing)
            return existing
        end
        # Read pools (Python-parity): reuse a checksum-verified copy from a known global
        # location (another project's download) rather than re-fetching — recorded, not copied.
        pooled = resolve_from_pools(db, dataset; extract=extract)
        if !isempty(pooled)
            info("Dataset reused from read pool: $pooled")
            record_dataset_state(db, dataset, pooled)
            return pooled
        end
    end

    did_fetch = false

    # Fetch ladder rung 3 — cross-language fetch (the rare case): no own Julia fetcher, no
    # shell fetcher, no `uri`, but a foreign-language fetcher exists. Delegate to the peer
    # `datamanifest` CLI, which materializes the result in the shared store; we then read it.
    if db.schema == 1 && (overwrite || !(isfile(download_path) || isdir(download_path))) &&
       dataset.lang_julia_fetcher == "" && _bare_fetcher_ref(dataset) == "" &&
       _shell_command(dataset) == "" &&
       isempty(dataset.uris) && dataset.uri == "" &&
       _should_delegate(dataset) && !isempty(_foreign_fetcher_langs(dataset))
        if _delegate_fetch(db, name)
            existing = resolve_existing_path(db, dataset; extract=extract)
            if isfile(existing) || isdir(existing)
                info("Dataset fetched via peer CLI: $existing")
                verify_checksum(db, dataset; extract=extract, skip_if_complete=true)
                record_dataset_state(db, dataset, existing)
                return existing
            end
        end
        # delegation off/unavailable/failed → fall through (the path below errors clearly).
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
                path = get_dataset_path(db, dep_entry; extract=extract !== nothing ? extract : dep_entry.extract)
                req_paths_by_ref[_sanitize_ref(ref)] = path
            end
            for dep_name in order[1:end-1]
                (_, dep_entry) = search_dataset(db, dep_name; kwargs...)
                push!(req_paths_ordered, get_dataset_path(db, dep_entry; extract=extract !== nothing ? extract : dep_entry.extract))
            end
        end
        # On lock contention, wait for the peer fetching this same target; unless an
        # explicit overwrite was requested, adopt what it published instead of re-fetching.
        materialize(download_path; skip_if=(t -> !overwrite && is_complete(t)),
                    stale_age=lock_stale_age(storage_config=storage_layers(db))) do tmp
            _download_dataset(dataset, tmp; project_root=project_root, overwrite=overwrite,
                             required_paths_by_ref=req_paths_by_ref, required_paths_ordered=req_paths_ordered,
                             loaders_julia_modules=db.loaders_julia_modules, db=db)
        end
        did_fetch = true
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

    if !(isfile(local_path) || isdir(local_path))
        _missing_dataset_error(dataset, local_path)
    end

    verify_checksum(db, dataset; extract=extract, skip_if_complete=!did_fetch)

    # spec-v4.1: record the resolved location (+ actual sha256) in the state file inventory.
    record_dataset_state(db, dataset, local_path)

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

# Resolve a loader binding (string or `{ ref, args, kwargs }` table) to a `path -> value`
# function: the conventional call `fn(path)` for a ref-only binding, or a parameterized call
# `ref(args...; kwargs...)` (with `$var`/`$path` substitution) when args/kwargs are present.
function _loader_from_binding(db::Database, entry::DatasetEntry, b)
    ref, args, kwargs = _parse_binding(b)
    isempty(ref) && error("loader binding has no `ref`.")
    fn = _resolve_ref(db, ref)
    (isempty(args) && isempty(kwargs)) && return fn
    return function (path)
        subs = _binding_subst_pairs(entry, "\$path" => path, get_project_root(db))
        a = _subst_binding_value(args, subs)
        kw = _kwargs_pairs(_subst_binding_value(kwargs, subs))
        return Base.invokelatest(fn, a...; kw...)
    end
end

# v1 load ladder (spec-v3.4/3.6):
#   1. own `[<ds>._LANG.julia].loader`, else the bare (language-implicit) `loader`;
#   2. `[_LANG.julia.loaders][format]`, else `[_LOADERS][format]` (language-implicit);
#   3. built-in format default; else error.
# At each own-language rung the explicit `_LANG.julia` binding wins over the bare one. A
# binding that is **present** for Julia (bare or explicit) is treated alike: spec-v3.6 —
# **fail loud**, it resolves-or-errors, and a runtime error propagates; the ladder falls
# through only past **absent** bindings, never to paper over a broken present one. A v1
# loader never spawns a subprocess / never `include_string`s.
function _resolve_loader_v1(db::Database, entry::DatasetEntry)
    # rung 1 — explicit own loader, else the bare language-implicit loader (both present-for-
    # Julia ⇒ resolve-or-error, no silent fall-through).
    entry.lang_julia_loader != "" && return _loader_from_binding(db, entry, entry.lang_julia_loader)
    entry.loader != "" && return _loader_from_binding(db, entry, entry.loader)
    # For extracted archives, path is a directory; no single-file format to load.
    format = (entry.extract && entry.format in COMPRESSED_FORMATS) ? "" : entry.format
    fmt = lowercase(strip(format))
    if !isempty(fmt)
        # rung 2 — `[_LANG.julia.loaders][fmt]`, else `[_LOADERS][fmt]` (language-implicit).
        for (k, b) in pairs(db.lang_julia_loaders)
            lowercase(strip(k)) == fmt && return _loader_from_binding(db, entry, b)
        end
        for (k, b) in pairs(db.loaders)
            lowercase(strip(k)) == fmt && return _loader_from_binding(db, entry, b)
        end
    end
    # rung 3 — built-in format default.
    if isempty(fmt)
        error("No loader resolved for dataset \"$(entry.key)\": no own/bare `loader`, no " *
              "`[_LANG.julia.loaders]`/`[_LOADERS]` entry, and the dataset format is empty.")
    end
    try
        return builtin_default_loader(format)
    catch
        error("No loader resolved for dataset \"$(entry.key)\" (format \"$format\"): no own/bare " *
              "`loader`, no `[_LANG.julia.loaders][$fmt]`/`[_LOADERS][$fmt]`, and no built-in loader.")
    end
end

# World-age errors are MethodError with world != typemax(UInt); "no matching method" uses typemax(UInt).
function _is_world_age_error(e)
    return e isa MethodError && e.world != typemax(UInt)
end

function _call_loader(fn::Function, path::String, entry::DatasetEntry)
    try
        return fn(path)
    catch e
        if _is_world_age_error(e) || e isa MethodError
            return Base.invokelatest(fn, path)
        end
        rethrow(e)
    end
end

function load_dataset(db::Database, name::String; loader=nothing, kwargs...)
    (_, entry) = search_dataset(db, name; kwargs...)
    return load_dataset(db, entry; loader=loader, kwargs...)
end

# Whether a dataset has a loader binding usable for in-place (lazy_access) opening — an
# explicit `loader=`, a per-dataset `loader` / `_LANG.julia.loader`, or a manifest-configured
# loader for its `format`. The built-in format default (which reads a *local* file) does NOT
# count: it cannot open a remote `uri`.
function _has_lazy_loader(db::Database, entry::DatasetEntry, loader)::Bool
    (loader !== nothing && loader != "") && return true
    (entry.loader != "" || entry.lang_julia_loader != "") && return true
    fmt = lowercase(strip(entry.format))
    isempty(fmt) && return false
    any(k -> lowercase(String(k)) == fmt, keys(db.lang_julia_loaders)) && return true
    any(k -> lowercase(String(k)) == fmt, keys(db.loaders)) && return true
    return false
end

function load_dataset(db::Database, entry::DatasetEntry; loader=nothing, kwargs...)
    # spec-v4.3: a bare `lazy_access` (no loader) is an error — there is no local file, so the
    # built-in default loader cannot open the in-place `uri`.
    if entry.lazy_access && !_has_lazy_loader(db, entry, loader)
        error("Dataset \"$(entry.key)\" sets `lazy_access` (open the uri in place) but has no " *
              "loader. lazy_access requires a loader that can open \"$(entry.uri)\": pass " *
              "loader=…, set a per-dataset `loader` / `[<ds>._LANG.julia].loader`, or configure " *
              "a `[_LANG.julia.loaders][\"$(entry.format)\"]`.")
    end
    path = download_dataset(db, entry; kwargs...)
    if loader !== nothing && loader != ""
        if loader isa String
            if haskey(db.loaders, loader)
                loader = _get_loader_function(db, loader)
            else
                # Resolve to built-in format loader (csv, yaml, nc, etc.) when not in _LOADERS
                try
                    loader = builtin_default_loader(loader)
                catch
                    error("loader must be a callable or a loader name defined in _LOADERS, or a built-in format (csv, parquet, nc, dimstack, md, txt, json, yaml, yml, toml, zip, tar, tar.gz). Got: \"$loader\"")
                end
            end
        end
        return _call_loader(loader, path, entry)
    elseif db.schema == 1
        # Parameterized own-loader binding: substitute `$var` (incl. `$path`) and
        # call `ref(args...; kwargs...)`. Only taken when args/kwargs are present.
        if entry.lang_julia_loader != "" &&
           (!isempty(entry.lang_julia_loader_args) || !isempty(entry.lang_julia_loader_kwargs))
            fn = _resolve_ref(db, entry.lang_julia_loader)
            subs = _binding_subst_pairs(entry, "\$path" => path, get_project_root(db))
            args = _subst_binding_value(entry.lang_julia_loader_args, subs)
            kwargs = _kwargs_pairs(_subst_binding_value(entry.lang_julia_loader_kwargs, subs))
            return Base.invokelatest(fn, args...; kwargs...)
        end
        # v1 load ladder: own `_LANG.julia.loader` ref → manifest
        # `[_LANG.julia.loaders][format]` ref → built-in format default → error.
        fn = _resolve_loader_v1(db, entry)
        return _call_loader(fn, path, entry)
    elseif entry.loader != ""
        # v0/legacy inline (or named/ref) loader.
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

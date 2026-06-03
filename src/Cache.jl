# Cache.jl — the produce-or-load (`@cached`) companion layer (spec-v3, capability
# `cache-produce`).
#
# A *produced* dataset's bytes come from running a project function rather than
# downloading a `uri`. It has NO entry in `datasets.toml`; its identity is
# `(cachetype, param-hash)` where the hash is the SHA-256 of the canonical JSON (JCS,
# RFC 8785) of its hash-affecting keyword parameters. On disk it lives at the composed
# path (Storage §Produced-artifact location)
#
#   <folder>/cached/[<scope>/]<cachetype>/[<version>/]<hash>/
#       ├── <basename>.<ext>   # the produced artifact
#       ├── config.toml        # the re-hashable key table + [_META]{schema,cachetype,hash}
#       ├── metadata.toml      # provenance (created/tool/host/user/[git]/[origin])
#       └── .complete          # completion marker
#
# This layer reuses the core substrate: folder resolution + the `cached` content prefix
# and project-scope (Storage), and the safe-materialization primitive (PipeLines). It
# never touches the fetch path. Only the on-disk formats + the param hash are normative;
# the `@cached` macro spelling is a per-language, non-normative ergonomic surface (its
# shape is ported from LGMIO's `@cached`).
#
# Included into the DataManifest module after Storage / PipeLines.
module Cache

using TOML
using SHA
using Dates
using Serialization
using ..Storage: store_dir, is_complete, marker_path
using ..PipeLines: materialize

export @cached, param_hash, cache_key, cached_dir,
    save_cache, load_cache, has_cache, read_config, config_is_valid, register_format!

# ── Canonical JSON (JCS, RFC 8785) + parameter hash ──────────────────────────

# Normalize a hash-input value to the spec-v3 restricted set (string / integer /
# boolean / array / object of those). Symbols are coerced to strings (a clean,
# deterministic projection). Floats, nulls, and anything else are a hard error —
# spec-v3 disallows them in hash inputs (pass a float as a string).
function _normalize_hashval(x)
    if x isa Bool
        return x
    elseif x isa Integer
        return Int(x)
    elseif x isa AbstractString
        return String(x)
    elseif x isa Symbol
        return String(x)
    elseif x isa AbstractVector || x isa Tuple
        return Any[_normalize_hashval(v) for v in x]
    elseif x isa NamedTuple
        return Dict{String,Any}(String(k) => _normalize_hashval(v) for (k, v) in pairs(x))
    elseif x isa AbstractDict
        return Dict{String,Any}(String(k) => _normalize_hashval(v) for (k, v) in x)
    elseif x isa AbstractFloat
        error("@cached: hash input contains a float ($x); spec-v3 disallows floats in " *
              "hash inputs — pass it as a string (e.g. \"$(x)\"), which is also more " *
              "hash-stable.")
    elseif x === nothing || x === missing
        error("@cached: hash input contains null/nothing; spec-v3 disallows nulls in hash " *
              "inputs. Omit the parameter or pass a sentinel string instead.")
    else
        error("@cached: hash input contains an unsupported value of type $(typeof(x)); " *
              "allowed: string, integer, boolean, and arrays/objects of those.")
    end
end

# The normalized, hash-ready key table: every top-level key except `_`-prefixed runtime
# knobs, recursively normalized to the restricted value set.
function _key_table(kt)::Dict{String,Any}
    d = _normalize_hashval(kt)
    d isa AbstractDict || error("@cached: the key must be a table (NamedTuple/Dict), got $(typeof(kt))")
    return Dict{String,Any}(k => v for (k, v) in d if !startswith(k, "_"))
end

# Minimal JSON string escaping per RFC 8785 (ECMAScript JSON.stringify): escape `"`,
# `\`, and control chars < 0x20 (with \b \t \n \f \r short forms); emit everything else
# (incl. non-ASCII) as raw UTF-8.
function _jcs_string(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\r'
            print(io, "\\r")
        elseif c < '\x20'
            print(io, "\\u", lowercase(string(UInt16(c); base=16, pad=4)))
        else
            print(io, c)
        end
    end
    print(io, '"')
end

# Serialize a normalized value to canonical JSON: object members sorted by Unicode code
# point at every level, no insignificant whitespace, array order preserved.
function _jcs(io::IO, x)
    if x isa Bool
        print(io, x ? "true" : "false")
    elseif x isa Integer
        print(io, string(x))
    elseif x isa AbstractString
        _jcs_string(io, x)
    elseif x isa AbstractVector
        print(io, '[')
        for (i, v) in enumerate(x)
            i > 1 && print(io, ',')
            _jcs(io, v)
        end
        print(io, ']')
    elseif x isa AbstractDict
        ks = sort!(collect(keys(x)))   # code-point order
        print(io, '{')
        for (i, k) in enumerate(ks)
            i > 1 && print(io, ',')
            _jcs_string(io, k)
            print(io, ':')
            _jcs(io, x[k])
        end
        print(io, '}')
    else
        error("@cached: cannot canonicalize value of type $(typeof(x))")
    end
end

"""
    canonical_json(key_table) -> String

The canonical-JSON (JCS / RFC 8785) projection of a key table — the exact bytes the
parameter hash is taken over. Restricted to strings / integers / booleans / arrays /
objects of those.
"""
function canonical_json(key_table)::String
    io = IOBuffer()
    _jcs(io, _key_table(key_table))
    return String(take!(io))
end

"""
    param_hash(key_table) -> String

Lowercase 64-hex SHA-256 of the canonical JSON of `key_table` (its hash-affecting keyword
parameters; `_`-prefixed keys are excluded). The cross-tool normative parameter hash.

Reference vector: `param_hash(Dict("grid"=>"5x5","skip_models"=>["CESM.*","FGOALS.*"]))` ==
`"83425a30d111562d46c1fce9de7618ea7f1f54e1be72e086cba0ac63c6f2ce9b"`.
"""
param_hash(key_table)::String = bytes2hex(sha256(canonical_json(key_table)))

"""
    cache_key(cachetype, hash; version=nothing) -> String

The portable storage key: `"<cachetype>/<hash>"`, or `"<cachetype>/<version>/<hash>"` when
a recipe `version` is set.
"""
function cache_key(cachetype::AbstractString, hash::AbstractString; version=nothing)::String
    (version === nothing || isempty(version)) ? "$(cachetype)/$(hash)" :
        "$(cachetype)/$(version)/$(hash)"
end

# ── Produced-artifact location ────────────────────────────────────────────────

"""
    cached_dir(cachetype, hash; version=nothing, store="\$cache", cache_dir=nothing,
               storage_config=Dict(), env=ENV, host=gethostname(), project_root="",
               declared_project="") -> String

The directory holding a produced artifact and its sidecars. With an explicit `cache_dir`,
it is used **verbatim** (`<cache_dir>/<cachetype>/[<version>/]<hash>`), bypassing folder /
prefix / scope. Otherwise it composes via the `cached` content prefix and the cached scope
(default: the project id): `<folder>/cached/[<scope>/]<cachetype>/[<version>/]<hash>`.
"""
function cached_dir(cachetype::AbstractString, hash::AbstractString;
                    version=nothing, store::AbstractString="\$cache",
                    cache_dir=nothing,
                    storage_config::AbstractDict=Dict{String,Any}(),
                    env=ENV, host::AbstractString=gethostname(),
                    project_root::AbstractString="", declared_project::AbstractString="")::String
    leaf = (version === nothing || isempty(version)) ?
        joinpath(cachetype, hash) : joinpath(cachetype, version, hash)
    if cache_dir !== nothing && !isempty(string(cache_dir))
        return joinpath(String(cache_dir), leaf)
    end
    base = store_dir(store, :cached; storage_config=storage_config, env=env, host=host,
                     project_root=project_root, declared_project=declared_project)
    return joinpath(base, leaf)
end

# ── Sidecars (config.toml + metadata.toml) ────────────────────────────────────

# TOML-safe coercion for values that are written but never hashed (metadata extras): keeps
# floats/etc. (unlike the hash path), stringifies Symbols, drops nothing.
_toml_safe(x::Bool) = x
_toml_safe(x::Number) = x
_toml_safe(x::AbstractString) = String(x)
_toml_safe(x::Symbol) = String(x)
_toml_safe(x::AbstractVector) = Any[_toml_safe(v) for v in x]
_toml_safe(x::Tuple) = Any[_toml_safe(v) for v in x]
_toml_safe(x::NamedTuple) = Dict{String,Any}(String(k) => _toml_safe(v) for (k, v) in pairs(x))
_toml_safe(x::AbstractDict) = Dict{String,Any}(String(k) => _toml_safe(v) for (k, v) in x)
_toml_safe(::Nothing) = ""
_toml_safe(x) = string(x)

"""
    write_config(dir, key_table, cachetype; version=nothing, hash=nothing) -> String

Write `<dir>/config.toml`: the key table at the root (written first) plus a `[_META]` block
(`schema`, `cachetype`, optional `version`, `hash`). Returns the hash.
"""
function write_config(dir::AbstractString, key_table, cachetype::AbstractString;
                      version=nothing, hash=nothing)::String
    kt = _key_table(key_table)
    h = hash === nothing ? bytes2hex(sha256(canonical_json(kt))) : String(hash)
    meta = Dict{String,Any}("schema" => 1, "cachetype" => String(cachetype), "hash" => h)
    (version !== nothing && !isempty(version)) && (meta["version"] = String(version))
    out = Dict{String,Any}(kt)
    out["_META"] = meta
    open(joinpath(dir, "config.toml"), "w") do io
        TOML.print(io, out; sorted=true)
    end
    return h
end

"""
    read_config(dir) -> (; key_table, cachetype, version, hash)

Read `<dir>/config.toml`: the key table is every root key except the `[_META]` block.
"""
function read_config(dir::AbstractString)
    t = TOML.parsefile(joinpath(dir, "config.toml"))
    meta = get(t, "_META", Dict{String,Any}())
    kt = Dict{String,Any}(k => v for (k, v) in t if k != "_META")
    return (key_table=kt, cachetype=get(meta, "cachetype", ""),
            version=get(meta, "version", nothing), hash=get(meta, "hash", ""))
end

"""
    config_is_valid(dir) -> Bool

`true` iff `<dir>/config.toml` exists and the hash recomputed from its key table equals the
recorded `_META.hash` (the re-hashability contract). A directory that fails this MUST NOT be
treated as a valid cache hit.
"""
function config_is_valid(dir::AbstractString)::Bool
    isfile(joinpath(dir, "config.toml")) || return false
    c = read_config(dir)
    return !isempty(c.hash) && param_hash(c.key_table) == c.hash
end

function _git_audit_block(project_root::AbstractString="")
    git = Dict{String,Any}("commit" => "unknown", "branch" => "unknown", "dirty" => false)
    repo = isempty(project_root) ? pwd() : String(project_root)
    try
        git["commit"] = strip(read(`git -C $repo rev-parse --short HEAD`, String))
        git["branch"] = strip(read(`git -C $repo rev-parse --abbrev-ref HEAD`, String))
        git["dirty"] = !isempty(strip(read(`git -C $repo status --porcelain`, String)))
    catch e
        e isa Union{Base.IOError,Base.ProcessFailedException,SystemError} || rethrow()
    end
    return git
end

_tool_string() = begin
    v = try
        pkgversion(@__MODULE__)
    catch
        nothing
    end
    v === nothing ? "DataManifest.jl" : "DataManifest.jl $(v)"
end

"""
    write_metadata(dir; cachetype, extras=Dict(), cached_toml=nothing, project_root="") -> String

Write `<dir>/metadata.toml` (provenance: `created`/`tool`/`host`/`user`/`[git]`, plus an
optional `[origin].cached_toml`). **Write-if-absent** — a cache hit never re-stamps it.
`extras` (audit-only, never hashed) are merged last and may override defaults.
"""
function write_metadata(dir::AbstractString; cachetype::AbstractString="",
                        extras=Dict{String,Any}(), cached_toml=nothing,
                        project_root::AbstractString="")::String
    path = joinpath(dir, "metadata.toml")
    isfile(path) && return path
    audit = Dict{String,Any}(
        "_META" => Dict{String,Any}("schema" => 1),
        "created" => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z"),
        "tool" => _tool_string(),
        "host" => gethostname(),
        "user" => get(ENV, "USER", get(ENV, "USERNAME", "unknown")),
        "git" => _git_audit_block(project_root),
    )
    (cached_toml !== nothing && !isempty(string(cached_toml))) &&
        (audit["origin"] = Dict{String,Any}("cached_toml" => String(cached_toml)))
    for (k, v) in _toml_safe(extras)
        audit[k] = v
    end
    open(path, "w") do io
        TOML.print(io, audit; sorted=true)
    end
    return path
end

# ── Artifact serialization (format registry; jls built-in) ────────────────────
#
# The produced-artifact byte format is per-tool / per-`format` and NOT assumed
# cross-language-loadable (spec §What this spec does not specify). The core ships `jls`
# (stdlib Serialization); heavy formats (nc, jld2, …) register a (save, load) pair from a
# package extension, mirroring the read-side loader ladder.

const _FORMATS = Dict{String,NamedTuple{(:save, :load),Tuple{Function,Function}}}()

"""
    register_format!(ext, save, load)

Register a produced-artifact (de)serializer for extension `ext`: `save(data, path)` and
`load(path)`. Lets an extension add `nc`/`jld2`/… without a hard dependency in the core.
"""
register_format!(ext::AbstractString, save::Function, load::Function) =
    (_FORMATS[String(ext)] = (save=save, load=load); nothing)

function _produce_save(data, path::AbstractString, ext::AbstractString)
    if ext == "jls"
        Serialization.serialize(path, data)
    elseif haskey(_FORMATS, ext)
        _FORMATS[ext].save(data, path)
    else
        error("@cached: no writer for format \"$(ext)\" (built-in: jls). Register one with " *
              "DataManifest.Cache.register_format!(\"$(ext)\", save, load).")
    end
    return path
end

function _produce_load(path::AbstractString, ext::AbstractString)
    if ext == "jls"
        return Serialization.deserialize(path)
    elseif haskey(_FORMATS, ext)
        return _FORMATS[ext].load(path)
    else
        error("@cached: no reader for format \"$(ext)\" (built-in: jls). Register one with " *
              "DataManifest.Cache.register_format!(\"$(ext)\", save, load).")
    end
end

# ── Cache context (where produced artifacts default to) ───────────────────────
#
# Without a Database in scope, the produced path resolves from the environment (the
# `$cache` folder) + the active project (for the cached scope = project id, and the git
# audit anchor). An explicit `cache_dir` per call overrides location entirely.

function _cache_context()
    proot = try
        dirname(Base.active_project())
    catch
        pwd()
    end
    return (storage_config=Dict{String,Any}(), project_root=proot, declared_project="")
end

# ── save / load / has (functional API used by the macro and directly) ─────────

"""
    save_cache(data, cachetype, key_table; ext="jls", basename="data", version=nothing,
               store="\$cache", cache_dir=nothing, extras=Dict()) -> String

Materialize `data` as a produced artifact at the composed cache directory and write the
`config.toml` / `metadata.toml` sidecars. Returns the artifact directory.
"""
function save_cache(data, cachetype::AbstractString, key_table;
                    ext::AbstractString="jls", basename::AbstractString="data",
                    version=nothing, store::AbstractString="\$cache", cache_dir=nothing,
                    extras=Dict{String,Any}())::String
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    materialize(dir) do tmp
        mkpath(tmp)
        _produce_save(data, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root)
    end
    return dir
end

"""
    has_cache(cachetype, key_table; version=nothing, store="\$cache", cache_dir=nothing) -> Bool

`true` iff a complete, hash-valid produced artifact exists for these parameters.
"""
function has_cache(cachetype::AbstractString, key_table;
                   version=nothing, store::AbstractString="\$cache", cache_dir=nothing)::Bool
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    return is_complete(dir) && config_is_valid(dir)
end

"""
    load_cache(cachetype, key_table; ext="jls", basename="data", version=nothing,
               store="\$cache", cache_dir=nothing) -> data or nothing

Return the produced artifact for these parameters, or `nothing` on a miss.
"""
function load_cache(cachetype::AbstractString, key_table;
                    ext::AbstractString="jls", basename::AbstractString="data",
                    version=nothing, store::AbstractString="\$cache", cache_dir=nothing)
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    (is_complete(dir) && config_is_valid(dir)) || return nothing
    return _produce_load(joinpath(dir, "$(basename).$(ext)"), ext)
end

# The produce-or-load core invoked by the `@cached` wrapper: fast-path load on a hit,
# otherwise compute + save under the safe-materialization primitive.
function _run_cached(body::Function, cachetype::AbstractString, key_table;
                     ext::AbstractString="jls", basename::AbstractString="data",
                     version=nothing, store::AbstractString="\$cache", cache_dir=nothing,
                     extras=Dict{String,Any}())
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    artifact = joinpath(dir, "$(basename).$(ext)")
    if is_complete(dir) && config_is_valid(dir)
        return _produce_load(artifact, ext)
    end
    local result
    materialize(dir) do tmp
        mkpath(tmp)
        result = body()
        _produce_save(result, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root)
    end
    return result
end

# ── @cached macro (non-normative ergonomic surface; ported from LGMIO) ─────────

# Extract the argument name from a signature expression (sym, sym::T, sym=default,
# sym::T=default).
function _cached_argname(ex)
    if isa(ex, Symbol)
        return ex
    elseif Meta.isexpr(ex, :kw)
        return _cached_argname(ex.args[1])
    elseif Meta.isexpr(ex, :(::))
        return _cached_argname(ex.args[1])
    elseif Meta.isexpr(ex, :...)
        error("@cached does not support splat arguments: $(ex)")
    else
        error("@cached: cannot extract name from argument expression: $(ex)")
    end
end

"""
    @cached cachetype="name" key=(args -> (;…)) [ext="jls"] [basename="data"]
            [version="v3"] [store="\$cache"] function fn(; kw…) … end

Wrap a **keyword-only** function with transparent produce-or-load disk caching (spec-v3
`cache-produce`).

- `cachetype` (String literal, required): the artifact namespace.
- `key` (required): a callable receiving a NamedTuple of the function's hash-affecting
  keyword arguments (every declared kwarg except `_`-prefixed runtime knobs) and returning
  the **key table** (a NamedTuple/Dict). Its canonical-JSON SHA-256 is the parameter hash.
  Hash inputs are restricted to strings/integers/booleans/arrays/objects of those — floats
  and nulls raise (pass a float as a string).
- `ext` (default `"jls"`): artifact serialization format. `jls` (stdlib `Serialization`) is
  built in; register others with `DataManifest.Cache.register_format!`.
- `basename` (default `"data"`), `version` (optional recipe/code version → a path segment,
  not in the hash), `store` (default `"\$cache"`).

The wrapper injects a `cached::Bool=true` escape hatch (`cached=false` runs the body with no
disk I/O). A kwarg named exactly `_metadata_extras` (NamedTuple/Dict/`nothing`) is an
audit-only channel merged into `metadata.toml` without affecting the hash; any other
`_`-prefixed kwarg is a runtime knob excluded from the hash but visible in the body.

**Produced datasets are keyword-only** — a function with positional arguments is rejected
(a positional list has no stable name→value identity to hash).
"""
macro cached(args...)
    length(args) >= 2 || error("@cached expects at least `cachetype=...`, `key=...`, and a function definition")
    fdef = args[end]
    kw_args = args[1:end-1]

    cachetype = nothing
    keyfn = nothing
    ext = nothing
    basename = nothing
    version = nothing
    store = nothing
    for kw in kw_args
        Meta.isexpr(kw, :(=)) || error("@cached: expected `name=value`, got $(kw)")
        name, val = kw.args
        if name === :cachetype
            isa(val, String) || error("@cached: `cachetype` must be a String literal")
            cachetype = val
        elseif name === :key
            keyfn = val
        elseif name === :ext
            isa(val, String) || error("@cached: `ext` must be a String literal")
            ext = val
        elseif name === :basename
            isa(val, String) || error("@cached: `basename` must be a String literal")
            basename = val
        elseif name === :version
            isa(val, String) || error("@cached: `version` must be a String literal")
            version = val
        elseif name === :store
            isa(val, String) || error("@cached: `store` must be a String literal")
            store = val
        else
            error("@cached: unknown argument `$name`. Expected `cachetype`, `key`, `ext`, `basename`, `version`, or `store`.")
        end
    end
    cachetype === nothing && error("@cached: missing required `cachetype=...`")
    keyfn === nothing && error("@cached: missing required `key=...`")

    if Meta.isexpr(fdef, :block)
        fdefs = filter(x -> !(x isa LineNumberNode), fdef.args)
        length(fdefs) == 1 || error("@cached: expected exactly one function definition")
        fdef = fdefs[1]
    end
    Meta.isexpr(fdef, :function) || (Meta.isexpr(fdef, :(=)) && Meta.isexpr(fdef.args[1], :call)) ||
        error("@cached: expected a function definition, got $(fdef)")

    sig = fdef.args[1]
    body = fdef.args[2]
    Meta.isexpr(sig, :call) || error("@cached: unexpected signature form: $(sig)")
    fname = sig.args[1]
    rest = sig.args[2:end]

    pos_args = Any[]
    kw_params = Any[]
    for a in rest
        if Meta.isexpr(a, :parameters)
            append!(kw_params, a.args)
        else
            push!(pos_args, a)
        end
    end

    # spec-v3: produced datasets are keyword-only.
    if !isempty(pos_args)
        names = join(string.(_cached_argname.(pos_args)), ", ")
        error("@cached: produced datasets are keyword-only (spec-v3); `$(fname)` has " *
              "positional argument(s): $names. Make them keyword arguments.")
    end

    kw_names = Symbol[_cached_argname(a) for a in kw_params]
    :cached in kw_names && error("@cached: the wrapped function already has a `cached` argument")

    # Key NamedTuple: every declared kwarg except `_`-prefixed runtime knobs.
    key_names = Symbol[n for n in kw_names if !startswith(string(n), "_")]
    nt_args = Expr(:tuple, Expr(:parameters, [Expr(:kw, n, n) for n in key_names]...))

    has_meta_extras = :_metadata_extras in kw_names
    has_cache_dir = :cache_dir in kw_names

    new_kw_params = copy(kw_params)
    push!(new_kw_params, Expr(:kw, :(cached::Bool), true))
    new_sig = Expr(:call, fname, Expr(:parameters, new_kw_params...))

    build_extras = if has_meta_extras
        quote
            let _e = _metadata_extras
                if _e === nothing
                    Dict{String,Any}()
                elseif _e isa NamedTuple
                    Dict{String,Any}(string(k) => v for (k, v) in pairs(_e))
                elseif _e isa AbstractDict
                    Dict{String,Any}(string(k) => v for (k, v) in pairs(_e))
                else
                    error("@cached: `_metadata_extras` must be a NamedTuple, AbstractDict, or nothing; got $(typeof(_e))")
                end
            end
        end
    else
        :(Dict{String,Any}())
    end

    cd_expr = has_cache_dir ? :(cache_dir) : :(nothing)
    _ext = ext === nothing ? "jls" : ext
    _basename = basename === nothing ? "data" : basename
    _version = version === nothing ? nothing : version
    _store = store === nothing ? "\$cache" : store
    _run = GlobalRef(@__MODULE__, :_run_cached)

    body_fn = Expr(:(->), Expr(:tuple), body)

    wrapper = quote
        _body_fn = $body_fn
        if !cached
            return _body_fn()
        end
        _kt = $(keyfn)($nt_args)
        return $_run(_body_fn, $cachetype, _kt;
            ext=$_ext, basename=$_basename, version=$_version, store=$_store,
            cache_dir=$cd_expr, extras=$build_extras)
    end

    return esc(Expr(:function, new_sig, wrapper))
end

end # module Cache

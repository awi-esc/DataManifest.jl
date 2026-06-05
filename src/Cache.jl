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
using ..Storage: datacache_dir, datacache_pools, is_complete, marker_path, lock_path, tmp_path,
    user_state_dir
using ..PipeLines: materialize

export @cached, param_hash, cache_key, cached_dir,
    save_cache, load_cache, has_cache, read_config, config_is_valid, register_format!,
    # state file (.datamanifest-state.toml, spec-v4.1, schema 5)
    CachedIndex, read_index, read_index_or_empty, register!, index_keys, reachable_keys,
    has_instance, ref_of, instance_path_of, remove_instance!, recipe_records,
    register_dataset!, has_dataset, dataset_path_of, dataset_sha256_of, set_dataset_path!,
    remove_dataset!, dataset_records, write_index, locate_state,
    CACHED_INDEX_NAME, STATE_FILE_NAME,
    # usage log + last-access (best-effort, advisory; cross-tool with the Python CLI)
    usage_log_path, record_path!, read_usage, known_paths,
    iso_from_mtime, last_access,
    # inspect (store maintenance: enumerate / delete / move)
    CacheObject, find_produced_artifacts, enumerate_artifacts, delete_object, move_object

# ── Canonical JSON (JCS, RFC 8785) + parameter hash ──────────────────────────

# Normalize a hash-input value to the spec-v3.1 restricted set (string / integer / boolean /
# finite float / array / object of those). Symbols are coerced to strings (a clean,
# deterministic projection); finite floats are kept as Float64 (serialized via the normative
# Python `json.dumps` float form, see `_python_float_repr`). Non-finite floats (NaN/±Inf),
# nulls (nothing/missing), and anything else are a hard error.
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
        isfinite(x) || error("@cached: hash input contains a non-finite float ($x); NaN/±Inf " *
              "have no JSON representation and are not hash-stable — pass a finite float or a string.")
        return Float64(x)
    elseif x === nothing || x === missing
        error("@cached: hash input contains null/nothing; spec-v3 disallows nulls in hash " *
              "inputs. Omit the parameter or pass a sentinel string instead.")
    else
        error("@cached: hash input contains an unsupported value of type $(typeof(x)); " *
              "allowed: string, integer, boolean, finite float, and arrays/objects of those.")
    end
end

# ── Normative finite-float serialization (Python `json.dumps` form, spec-v3.1) ─
#
# spec-v3.1 permits finite floats as hash inputs and pins their canonical-JSON byte form to
# the Python reference `json.dumps` (= CPython `repr`): shortest round-tripping digits, with
# `1.0` → "1.0", `0.5` → "0.5", `1e20` → "1e+20", `1e-5` → "1e-05". Julia's `string(::Float64)`
# differs in scientific notation (`1.0e20`, no `+`, always `.0`), so we recover the shortest
# digits + decimal exponent from Julia's (Ryū) shortest repr and reformat per CPython's
# `format_float_short` rules: exponential iff `decpt <= -4 || decpt > 16`, else fixed, with a
# signed ≥2-digit exponent and a trailing `.0` only on integer-valued fixed output.

# Reformat (significant `digits`, decimal point position `decpt`) into CPython's `repr` form.
function _python_format_digits(digits::String, decpt::Int)::String
    n = length(digits)
    if decpt <= -4 || decpt > 16
        expo = decpt - 1
        mant = n == 1 ? string(digits[1]) : string(digits[1], ".", digits[2:end])
        sgn = expo < 0 ? "-" : "+"
        ea = abs(expo)
        es = ea < 10 ? string("0", ea) : string(ea)
        return string(mant, "e", sgn, es)
    elseif decpt <= 0
        return string("0.", "0"^(-decpt), digits)
    elseif decpt >= n
        return string(digits, "0"^(decpt - n), ".0")
    else
        return string(digits[1:decpt], ".", digits[decpt+1:end])
    end
end

"""
    _python_float_repr(x::Float64) -> String

A finite `Float64` formatted byte-for-byte like Python's `repr` / `json.dumps` (the spec-v3.1
normative canonical-JSON float form). Reproduces e.g. `1.0`→"1.0", `0.5`→"0.5",
`1e20`→"1e+20", `1e-5`→"1e-05".
"""
function _python_float_repr(x::Float64)::String
    x == 0.0 && return signbit(x) ? "-0.0" : "0.0"
    neg = x < 0
    s = string(abs(x))                       # Julia shortest round-trip repr (Ryū)
    eidx = findfirst(==('e'), s)
    if eidx !== nothing
        mant = s[1:eidx-1]
        expo = parse(Int, s[eidx+1:end])
        dotidx = findfirst(==('.'), mant)
        intpart = dotidx === nothing ? mant : mant[1:dotidx-1]
        fracpart = dotidx === nothing ? "" : mant[dotidx+1:end]
        digits = intpart * fracpart
        decpt = expo + length(intpart)       # Julia normalizes to one leading digit
    else
        dotidx = findfirst(==('.'), s)
        intpart = dotidx === nothing ? s : s[1:dotidx-1]
        fracpart = dotidx === nothing ? "" : s[dotidx+1:end]
        digits = intpart * fracpart
        decpt = length(intpart)
    end
    while length(digits) > 1 && first(digits) == '0'   # strip leading zeros
        digits = digits[2:end]; decpt -= 1
    end
    while length(digits) > 1 && last(digits) == '0'     # strip trailing zeros
        digits = digits[1:end-1]
    end
    out = _python_format_digits(digits, decpt)
    return neg ? string("-", out) : out
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
    elseif x isa AbstractFloat
        print(io, _python_float_repr(Float64(x)))   # normative Python json.dumps form
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
    cached_dir(cachetype, hash; version=nothing, cache_dir=nothing, storage_config=Dict(),
               env=ENV, host=gethostname(), project_root="") -> String

The directory holding a produced artifact and its sidecars (spec-v4). With an explicit
`cache_dir`, it is used **verbatim** (`<cache_dir>/<cachetype>/[<version>/]<hash>`), the
experiment-folder workflow. Otherwise it composes under the manifest's **`datacache_dir`**
(default `<repo>/cached`): `<datacache_dir>/<cachetype>/[<version>/]<hash>`. No scope, prefix,
or partition — the folder is the location.
"""
function cached_dir(cachetype::AbstractString, hash::AbstractString;
                    version=nothing, cache_dir=nothing,
                    storage_config::AbstractDict=Dict{String,Any}(),
                    env=ENV, host::AbstractString=gethostname(),
                    project_root::AbstractString="")::String
    leaf = (version === nothing || isempty(version)) ?
        joinpath(cachetype, hash) : joinpath(cachetype, version, hash)
    if cache_dir !== nothing && !isempty(string(cache_dir))
        return joinpath(String(cache_dir), leaf)
    end
    base = datacache_dir(; storage_config=storage_config, env=env, host=host,
                         project_root=project_root)
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
    write_metadata(dir; cachetype, extras=Dict(), state_file=nothing, project_root="") -> String

Write `<dir>/metadata.toml` (provenance: `created`/`tool`/`host`/`user`/`[git]`, plus an
optional `[origin].state_file` back-pointer to the state file that inventories this artifact).
**Write-if-absent** — a cache hit never re-stamps it. `extras` (audit-only, never hashed) are
merged last and may override defaults.
"""
function write_metadata(dir::AbstractString; cachetype::AbstractString="",
                        extras=Dict{String,Any}(), state_file=nothing,
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
    (state_file !== nothing && !isempty(string(state_file))) &&
        (audit["origin"] = Dict{String,Any}("state_file" => String(state_file)))
    for (k, v) in _toml_safe(extras)
        audit[k] = v
    end
    open(path, "w") do io
        TOML.print(io, audit; sorted=true)
    end
    return path
end

# ── The state file (`.datamanifest-state.toml`, spec-v4.1, schema 5) ───────────
#
# The hand-authored `datasets.toml` is the committed SPEC (what to track + how to obtain it).
# WHERE each object actually landed on this machine is recorded separately in a sibling,
# git-ignored **`.datamanifest-state.toml`** — the state file — a tool-maintained inventory of
# both fetched datasets and produced artifacts. It is a read-only inventory: consulted to FIND
# an existing object, never to direct a write (writes follow the current directive). Schema 5
# has two namespaces:
#
#   [datacache."<cachetype>[@<version>]"]   — produced: ref/format + instances{hash → artifact dir}
#   [datasets."<key>"]                      — fetched:  storage_path + actual sha256
#
# `@` is the reserved version separator (a cachetype never contains `@`). The instance value is
# the full artifact directory (params are NOT stored here — they live in each config.toml).
# Older shapes (schema 1–4, the produced-only `cached.toml`) are still READ and rewritten
# forward; `cached.toml` is the recognized legacy filename. Mirrors the Python `cache/_index.py`.

const STATE_FILE_NAME = ".datamanifest-state.toml"
const CACHED_INDEX_NAME = STATE_FILE_NAME   # historical alias used across the codebase
const _LEGACY_INDEX_NAMES = ("cached.toml",)
const CACHED_INDEX_SCHEMA = 5
const _VERSION_SEP = "@"

# A recipe's identity: (cachetype, version).
const RecipeKey = Tuple{String,String}

# Recipe table key <-> (cachetype, version): `cachetype@version`, or a bare cachetype when
# unversioned (a cachetype never contains `@`, so the partition is unambiguous).
function _split_recipe_key(k::AbstractString)::RecipeKey
    ct, sep, ver = partition(String(k), _VERSION_SEP)
    return (ct, ver)
end
_join_recipe_key(ct::AbstractString, ver::AbstractString)::String =
    isempty(ver) ? String(ct) : "$(ct)$(_VERSION_SEP)$(ver)"

# Julia has no Base.partition; split on the first separator.
function partition(s::AbstractString, sep::AbstractString)
    i = findfirst(sep, s)
    i === nothing ? (s, "", "") : (s[1:first(i)-1], sep, s[last(i)+1:end])
end

"""
    CachedIndex(; recipes=Dict(), datasets=Dict(), path="")

In-memory view of a `.datamanifest-state.toml` (schema 5): `recipes` (produced) maps a recipe
identity `(cachetype, version)` to `Dict("ref","format","instances" => Dict(hash => storage_path))`
— each per-instance value the recorded full artifact directory; `datasets` (fetched) maps a
storage `key` to `Dict("storage_path","sha256")`. `path` is the file read from / written to.
"""
mutable struct CachedIndex
    recipes::Dict{RecipeKey,Any}
    datasets::Dict{String,Any}
    path::String
end
CachedIndex(; recipes=Dict{RecipeKey,Any}(), datasets=Dict{String,Any}(),
            path::AbstractString="") =
    CachedIndex(Dict{RecipeKey,Any}(recipes), Dict{String,Any}(datasets), String(path))

# Normalize `path` to a state-file path: a directory yields its canonical name; a file is
# returned verbatim (so an explicit legacy/custom name is honored).
function _index_resolve_path(path::AbstractString)::String
    p = String(path)
    isdir(p) && return joinpath(p, STATE_FILE_NAME)
    return p
end

# The path a WRITE targets: a directory or a legacy-named file migrates to the canonical
# sibling; a canonical/custom file path is honored verbatim.
function _index_canonical_path(path::AbstractString)::String
    p = String(path)
    isdir(p) && return joinpath(p, STATE_FILE_NAME)
    basename(p) in _LEGACY_INDEX_NAMES && return joinpath(dirname(p), STATE_FILE_NAME)
    return p
end

"""
    locate_state(base) -> String

The state file to **read** at `base` (a directory or file path): the canonical
`.datamanifest-state.toml` when present, else a legacy `cached.toml` sibling, else the
canonical path (which may not exist). Lets callers find an inventory under either name.
"""
function locate_state(base::AbstractString)::String
    b = String(base)
    isfile(b) && return b
    d = isdir(b) ? b : dirname(b)
    isempty(d) && (d = ".")
    canonical = joinpath(d, STATE_FILE_NAME)
    isfile(canonical) && return canonical
    for legacy in _LEGACY_INDEX_NAMES
        p = joinpath(d, legacy)
        isfile(p) && return p
    end
    return canonical
end

# Populate `recipes` from a `datacache` namespace (schema 5) or top-level recipe tables
# (schema 4) — both `key → recipe` maps with an `instances` hash→storage_path map.
function _read_datacache_namespace!(table, recipes::Dict{RecipeKey,Any})
    table isa AbstractDict || return
    for (k, rec) in table
        rec isa AbstractDict || continue
        key = _split_recipe_key(String(k))
        instances = Dict{String,Any}()
        insts = get(rec, "instances", Dict{String,Any}())
        if insts isa AbstractDict
            for (h, p) in insts
                p isa AbstractString && (instances[String(h)] = String(p))
            end
        end
        isempty(instances) && continue   # an instance-less recipe roots nothing
        recipes[key] = Dict{String,Any}(
            "ref" => String(get(rec, "ref", "")),
            "format" => String(get(rec, "format", "")),
            "instances" => instances)
    end
end

"""
    read_index(path) -> CachedIndex

Read a state file from `path` (a file, or a directory holding it under its canonical or
legacy name). Reads schema 5 (namespaced), schema 4 (top-level recipe tables), and the legacy
produced-only `cached.toml` shapes (schema 3 params-body, schema 2 `[[produced]]`, schema 1
flat) — all migrated forward; instance values become the per-variation artifact directory
(`""` when a legacy form did not record it).
"""
function read_index(path::AbstractString)::CachedIndex
    target = locate_state(path)
    t = TOML.parsefile(target)
    meta = get(t, "_META", Dict{String,Any}())
    schema = get(meta, "schema", 1)
    recipes = Dict{RecipeKey,Any}()
    datasets = Dict{String,Any}()
    if schema isa Integer && schema >= 5
        _read_datacache_namespace!(get(t, "datacache", Dict{String,Any}()), recipes)
        ds = get(t, "datasets", Dict{String,Any}())
        if ds isa AbstractDict
            for (k, rec) in ds
                rec isa AbstractDict || continue
                datasets[String(k)] = Dict{String,Any}(
                    "storage_path" => String(get(rec, "storage_path", "")),
                    "sha256" => String(get(rec, "sha256", "")))
            end
        end
    elseif schema isa Integer && schema == 4
        _read_datacache_namespace!(Dict(k => v for (k, v) in t if k != "_META"), recipes)
    elseif schema isa Integer && schema == 3
        # Legacy: instances are hash→params-body and the recipe carries one storage_path
        # (the parent dir). Migrate to per-instance full artifact dirs (parent/hash).
        for (k, rec) in t
            (k == "_META" || !(rec isa AbstractDict)) && continue
            ct, ver = _split_recipe_key(String(k))
            recipe_sp = String(get(rec, "storage_path", ""))
            instances = Dict{String,Any}()
            insts = get(rec, "instances", Dict{String,Any}())
            if insts isa AbstractDict
                for (h, _) in insts
                    instances[String(h)] = isempty(recipe_sp) ? "" : "$(recipe_sp)/$(h)"
                end
            end
            isempty(instances) && continue
            recipes[(ct, ver)] = Dict{String,Any}(
                "ref" => String(get(rec, "ref", "")),
                "format" => String(get(rec, "format", "")), "instances" => instances)
        end
    elseif schema isa Integer && schema == 2
        for rec in get(t, "produced", Any[])
            rec isa AbstractDict || continue
            key = (String(get(rec, "cachetype", "")), String(get(rec, "version", "")))
            instances = Dict{String,Any}()
            for inst in get(rec, "instances", Any[])
                inst isa AbstractDict || continue
                h = String(get(inst, "hash", ""))
                isempty(h) || (instances[h] = "")
            end
            isempty(instances) && continue
            recipes[key] = Dict{String,Any}(
                "ref" => String(get(rec, "ref", "")),
                "format" => String(get(rec, "format", "")), "instances" => instances)
        end
    else
        # Schema 1: a flat table per name with a single hash and no params.
        for (name, e) in t
            (name == "_META" || !(e isa AbstractDict)) && continue
            h = String(get(e, "hash", ""))
            isempty(h) && continue
            recipes[(String(get(e, "cachetype", "")), String(get(e, "version", "")))] =
                Dict{String,Any}("ref" => String(get(e, "ref", "")),
                                 "format" => String(get(e, "format", "")),
                                 "instances" => Dict{String,Any}(h => ""))
        end
    end
    return CachedIndex(recipes=recipes, datasets=datasets, path=target)
end

"""
    read_index_or_empty(path) -> CachedIndex

Read the state file at `path` (canonical or legacy name), or an empty one bound to the
canonical path when none exists — so the next [`write_index`] migrates a legacy file forward.
"""
function read_index_or_empty(path::AbstractString)::CachedIndex
    canonical = _index_canonical_path(path)
    target = locate_state(path)
    if isfile(target)
        idx = read_index(target)
        idx.path = canonical
        return idx
    end
    return CachedIndex(path=canonical)
end

# ----- produced recipes -----

"""
    register!(index; cachetype, hash, storage_path="", ref="", format="", version="")

Register the produced *variation* `hash` under its recipe `(cachetype, version)`, recording
the per-instance `storage_path` (the full artifact directory). Registering ACCUMULATES — a new
`hash` adds an instance rather than replacing the recipe. Recipe-level `ref`/`format` are
refreshed on each call. A `cachetype` may not contain the reserved separator `@`.
"""
function register!(index::CachedIndex;
                   cachetype::AbstractString, hash::AbstractString,
                   storage_path::AbstractString="",
                   ref::AbstractString="", format::AbstractString="",
                   version::AbstractString="")
    occursin(_VERSION_SEP, String(cachetype)) &&
        error("cachetype \"$(cachetype)\" may not contain \"$(_VERSION_SEP)\" " *
              "(reserved as the state-file version separator)")
    key = (String(cachetype), String(version))
    rec = get(index.recipes, key, nothing)
    if rec === nothing
        rec = Dict{String,Any}("ref" => String(ref), "format" => String(format),
                               "instances" => Dict{String,Any}())
        index.recipes[key] = rec
    else
        rec["ref"] = String(ref); rec["format"] = String(format)
    end
    rec["instances"][String(hash)] = String(storage_path)
    return index
end

"""
    has_instance(index; cachetype, version, hash) -> Bool

Whether this inventory already roots the variation `(cachetype, version, hash)`.
"""
function has_instance(index::CachedIndex; cachetype::AbstractString,
                      version::AbstractString, hash::AbstractString)::Bool
    rec = get(index.recipes, (String(cachetype), String(version)), nothing)
    rec === nothing && return false
    return haskey(rec["instances"], String(hash))
end

"""
    ref_of(index; cachetype, version) -> String or nothing

The recorded `ref` for a recipe, or `nothing` when the recipe is absent.
"""
function ref_of(index::CachedIndex; cachetype::AbstractString, version::AbstractString)
    rec = get(index.recipes, (String(cachetype), String(version)), nothing)
    rec === nothing ? nothing : String(rec["ref"])
end

"""
    instance_path_of(index; cachetype, version, hash) -> String

The recorded per-instance `storage_path` (artifact dir) of a variation, or `""` when absent.
"""
function instance_path_of(index::CachedIndex; cachetype::AbstractString,
                          version::AbstractString, hash::AbstractString)::String
    rec = get(index.recipes, (String(cachetype), String(version)), nothing)
    rec === nothing ? "" : String(get(rec["instances"], String(hash), ""))
end

"""
    remove_instance!(index; cachetype, version, hash) -> Bool

Drop a recorded variation (e.g. after a `--delete`); the recipe is removed once its last
instance is gone. Returns `true` if the instance existed.
"""
function remove_instance!(index::CachedIndex; cachetype::AbstractString,
                          version::AbstractString, hash::AbstractString)::Bool
    key = (String(cachetype), String(version))
    rec = get(index.recipes, key, nothing)
    (rec === nothing || !haskey(rec["instances"], String(hash))) && return false
    delete!(rec["instances"], String(hash))
    isempty(rec["instances"]) && delete!(index.recipes, key)
    return true
end

"""
    reachable_keys(index) -> Set{NTuple{3,String}}

The `(cachetype, version, hash)` tuples this inventory roots — every produced instance.
"""
function reachable_keys(index::CachedIndex)::Set{NTuple{3,String}}
    out = Set{NTuple{3,String}}()
    for ((ct, ver), rec) in index.recipes
        for h in keys(rec["instances"])
            push!(out, (ct, ver, String(h)))
        end
    end
    return out
end

"""
    index_keys(index) -> Set{String}

The set of portable cache keys `"<cachetype>/<hash>"` this inventory roots (produced).
Prefer [`reachable_keys`](@ref) for version-aware reachability.
"""
function index_keys(index::CachedIndex)::Set{String}
    out = Set{String}()
    for ((ct, _), rec) in index.recipes
        isempty(ct) && continue
        for h in keys(rec["instances"])
            isempty(h) || push!(out, "$(ct)/$(h)")
        end
    end
    return out
end

"""
    recipe_records(index) -> Vector{Dict}

The produced recipes as plain dicts (identity + metadata + `instances` mapping
`hash -> storage_path`), for inspection.
"""
function recipe_records(index::CachedIndex)::Vector{Dict{String,Any}}
    out = Dict{String,Any}[]
    for ((ct, ver), rec) in index.recipes
        push!(out, Dict{String,Any}(
            "cachetype" => ct, "version" => ver,
            "ref" => rec["ref"], "format" => rec["format"],
            "instances" => Dict{String,Any}(rec["instances"])))
    end
    return out
end

# ----- fetched datasets -----

"""
    register_dataset!(index; key, storage_path="", sha256="")

Record (or refresh) a fetched dataset's resolved location / checksum. Additive: a non-empty
`storage_path`/`sha256` overwrites the recorded one; an empty argument leaves the existing
value untouched (a `skip_checksum` re-record keeps any prior sha).
"""
function register_dataset!(index::CachedIndex; key::AbstractString,
                           storage_path::AbstractString="", sha256::AbstractString="")
    rec = get(index.datasets, String(key), nothing)
    if rec === nothing
        rec = Dict{String,Any}("storage_path" => "", "sha256" => "")
        index.datasets[String(key)] = rec
    end
    !isempty(storage_path) && (rec["storage_path"] = String(storage_path))
    !isempty(sha256) && (rec["sha256"] = String(sha256))
    return index
end

"""    has_dataset(index, key) -> Bool"""
has_dataset(index::CachedIndex, key::AbstractString)::Bool = haskey(index.datasets, String(key))

"""    dataset_path_of(index, key) -> String  (recorded resolved storage_path, or "")"""
dataset_path_of(index::CachedIndex, key::AbstractString)::String =
    String(get(get(index.datasets, String(key), Dict{String,Any}()), "storage_path", ""))

"""    dataset_sha256_of(index, key) -> String  (recorded actual sha256, or "")"""
dataset_sha256_of(index::CachedIndex, key::AbstractString)::String =
    String(get(get(index.datasets, String(key), Dict{String,Any}()), "sha256", ""))

"""    set_dataset_path!(index, key, storage_path) -> Bool  (repoint; e.g. after --move)"""
function set_dataset_path!(index::CachedIndex, key::AbstractString, storage_path::AbstractString)::Bool
    rec = get(index.datasets, String(key), nothing)
    rec === nothing && return false
    rec["storage_path"] = String(storage_path)
    return true
end

"""    remove_dataset!(index, key) -> Bool  (drop a recorded dataset; e.g. after --delete)"""
remove_dataset!(index::CachedIndex, key::AbstractString)::Bool =
    (pop!(index.datasets, String(key), nothing) !== nothing)

"""
    dataset_records(index) -> Vector{Dict}

The fetched datasets as plain dicts (`key`/`storage_path`/`sha256`), for inspection.
"""
function dataset_records(index::CachedIndex)::Vector{Dict{String,Any}}
    out = Dict{String,Any}[]
    for (k, rec) in index.datasets
        push!(out, Dict{String,Any}("key" => k,
            "storage_path" => String(get(rec, "storage_path", "")),
            "sha256" => String(get(rec, "sha256", ""))))
    end
    return out
end

# ----- serialization -----

# Build the schema-5 TOML structure: a `datacache` namespace of `["<cachetype>@<version>"]`
# recipe tables and a `datasets` namespace of per-key location/checksum tables. Empty
# namespaces are omitted. `write_index`'s `sorted=true` canonicalizes table keys on top.
function _index_to_dict(index::CachedIndex)::Dict{String,Any}
    out = Dict{String,Any}("_META" => Dict{String,Any}("schema" => CACHED_INDEX_SCHEMA))
    if !isempty(index.recipes)
        datacache = Dict{String,Any}()
        for ((ct, ver), rec) in index.recipes
            datacache[_join_recipe_key(ct, ver)] = Dict{String,Any}(
                "ref" => rec["ref"], "format" => rec["format"],
                "instances" => Dict{String,Any}(rec["instances"]))
        end
        out["datacache"] = datacache
    end
    if !isempty(index.datasets)
        ds = Dict{String,Any}()
        for (k, rec) in index.datasets
            entry = Dict{String,Any}("storage_path" => String(get(rec, "storage_path", "")))
            sha = String(get(rec, "sha256", ""))
            !isempty(sha) && (entry["sha256"] = sha)
            ds[k] = entry
        end
        out["datasets"] = ds
    end
    return out
end

"""
    write_index(index, path="") -> String

Write the state file to `path` (or its bound `path`, migrating a legacy name to the canonical
one), canonically ordered, via a temp file + atomic rename (so concurrent additive writers
never observe a half-written inventory). Returns the path written.
"""
function write_index(index::CachedIndex, path::AbstractString="")::String
    target = isempty(path) ? index.path : _index_canonical_path(path)
    isempty(target) && error("write_index: no path given and CachedIndex has no loaded path")
    target = _index_resolve_path(target)
    dir = dirname(target)
    !isempty(dir) && mkpath(dir)
    tmp = "$(target).$(getpid()).tmp"
    open(tmp, "w") do io
        TOML.print(io, _index_to_dict(index); sorted=true)
    end
    mv(tmp, target; force=true)
    index.path = target
    return target
end

# ── Usage log + last-access (best-effort, advisory; cross-tool with Python) ───
#
# Two facilities, both stdlib-only and never required for correctness:
#
#   1. usage log — a single `usage.toml` (under `user_state_dir`) recording every
#      datasets.toml / cached.toml index path the cache layer has read/written, each with a
#      `last_seen` RFC-3339 UTC stamp. A cheap index of where artifacts were registered.
#   2. last-access — the filesystem access time of a produced artifact directory, read at
#      inspect time by `last_access` (falling back to the modification time when atime is
#      unreadable). spec-v3.2: it is **filesystem-derived and never written on read** — the
#      reader MUST NOT touch any file/sidecar/index to record access (that would contend with
#      the produce `.lock`, serialize readers, and put I/O on the hot path for a purely
#      advisory value). The signal is coarse and may be absent (`relatime` advances atime at
#      most once a day; `noatime`/network/read-only filesystems record nothing); `created`
#      (stamped once at produce time) is the always-available age signal.

const USAGE_LOG_NAME = "usage.toml"
const _USAGE_ENV_OVERRIDE = "DATAMANIFEST_USAGE_LOG"

"""
    usage_log_path(env=ENV) -> String

The absolute path of the depot usage log. `\$DATAMANIFEST_USAGE_LOG` overrides; otherwise
`user_state_dir("datamanifest")/usage.toml`.
"""
function usage_log_path(env=ENV)::String
    override = get(env, _USAGE_ENV_OVERRIDE, "")
    !isempty(override) && return String(override)
    return joinpath(user_state_dir(env), USAGE_LOG_NAME)
end

_now_iso() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-dd\THH:MM:SS\Z")

# RFC-3339 UTC stamp of a unix-epoch time.
_iso_from_epoch(ts::Real) = Dates.format(Dates.unix2datetime(ts), dateformat"yyyy-mm-dd\THH:MM:SS\Z")

"""
    iso_from_mtime(path) -> String

RFC-3339 UTC stamp of `path`'s modification time (empty when `path` is absent).
"""
function iso_from_mtime(path::AbstractString)::String
    ispath(path) || return ""
    try
        return _iso_from_epoch(mtime(path))
    catch
        return ""
    end
end

# The filesystem access time (unix epoch) of `path`, or `nothing`. Base `stat` does not
# expose atime, so shell out to `stat` (GNU `-c %X`, BSD `-f %a`); unix-only, best-effort.
function _atime_epoch(path::AbstractString)
    try
        if Sys.isapple()
            return parse(Float64, strip(read(`stat -f %a $path`, String)))
        elseif Sys.isunix()
            return parse(Float64, strip(read(`stat -c %X $path`, String)))
        end
    catch
    end
    return nothing
end

"""
    last_access(path) -> String

The last time a produced artifact at `path` was read, as an RFC-3339 UTC stamp — read purely
from the filesystem (the directory's `stat` access time), **never written on read** (spec-v3.2).
Falls back to the modification time when atime is unreadable (e.g. an unsupported platform);
empty only when `path` is absent. Advisory and coarse: `relatime` advances atime at most once
a day and `noatime`/network/read-only filesystems record nothing, so this may be stale or
track mtime — use `created` for an always-available age signal, and never as the sole basis
for deletion.
"""
function last_access(path::AbstractString)::String
    ispath(path) || return ""
    ts = _atime_epoch(path)
    ts === nothing ? iso_from_mtime(path) : _iso_from_epoch(ts)
end

"""
    read_usage(env=ENV) -> Dict{String,Any}

The parsed usage log as `abspath => Dict("last_seen" => <iso>)` (empty when absent/unreadable).
"""
function read_usage(env=ENV)::Dict{String,Any}
    path = usage_log_path(env)
    isfile(path) || return Dict{String,Any}()
    try
        data = TOML.parsefile(path)
        paths = get(data, "paths", Dict{String,Any}())
        return paths isa AbstractDict ? Dict{String,Any}(paths) : Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

"""
    record_path!(index_path; env=ENV, now="") -> String

Record `index_path` (a datasets.toml / cached.toml) as seen now, stored absolute with a
`last_seen` RFC-3339 UTC stamp. Best-effort (never raises). Returns the absolute path.
"""
function record_path!(index_path::AbstractString; env=ENV, now::AbstractString="")::String
    ap = abspath(index_path)
    try
        paths = read_usage(env)
        paths[ap] = Dict{String,Any}("last_seen" => isempty(now) ? _now_iso() : String(now))
        log = usage_log_path(env)
        d = dirname(log)
        !isempty(d) && mkpath(d)
        open(log, "w") do io
            TOML.print(io, Dict{String,Any}("paths" => paths); sorted=true)
        end
    catch
    end
    return ap
end

"""
    known_paths(env=ENV) -> Vector{String}

The recorded index/manifest paths (sorted).
"""
known_paths(env=ENV)::Vector{String} = sort!(collect(keys(read_usage(env))))

# ── Inspect: enumerate / delete / move produced artifacts (spec-v3 `inspect`) ─
#
# The cache-layer half of the user-driven `datamanifest list … --delete` maintenance
# surface (spec-v3, replacing the retired automatic GC). Given a `$cache` root it
# enumerates the PRODUCED artifacts under it as field-bearing `CacheObject`s and deletes /
# moves an explicitly-selected subset. It reads only the folder it is handed — never the
# manifests, never `$data`/`$repo`. A produced artifact is exactly a directory holding a
# `config.toml` sidecar (which a fetched `store="$cache"` dataset lacks), so a fetched
# `$cache` dataset is never enumerated and never deleted. `referenced` is NOT decided here —
# the composition root (`DataManifest.inspect_store`) tags it from the project's cached.toml.
# Mirrors the Python `cache/_inspect.py`.

const _SIDECAR_NAMES = ("config.toml", "metadata.toml")

"""
    CacheObject

A maintenance view of one store object. `kind` is `"cached"` (produced artifact) or
`"datasets"` (fetched dataset). `key` is `"<cachetype>/<hash>"` (produced) or the dataset
name (fetched). `hash`/`cachetype`/`version` are produced-artifact identity; `format`,
`size`, `created`, `last_access` are inspectable fields; `referenced` is `true`/`false` once
a composition root resolves reachability, `nothing` while unknown.
"""
Base.@kwdef mutable struct CacheObject
    kind::String
    location::String
    key::String = ""
    hash::String = ""
    cachetype::String = ""
    version::String = ""
    format::String = ""
    size::Int = 0
    created::String = ""
    last_access::String = ""
    referenced::Union{Bool,Nothing} = nothing
end

"""
    find_produced_artifacts(cache_root) -> Vector{Tuple{String,String}}

`(artifact_dir, key)` for every produced artifact under `cache_root`. A produced artifact
is a directory holding a `config.toml` sidecar; its key is `"<cachetype>/<hash>"`. Walking
does not descend into an artifact directory once found.
"""
function find_produced_artifacts(cache_root::AbstractString)::Vector{Tuple{String,String}}
    out = Tuple{String,String}[]
    isdir(cache_root) || return out
    for (dirpath, dirnames, filenames) in walkdir(cache_root)
        if "config.toml" in filenames
            ct, h = "", ""
            try
                c = read_config(dirpath)
                ct, h = String(c.cachetype), String(c.hash)
            catch
                continue
            end
            (!isempty(ct) && !isempty(h)) && push!(out, (abspath(dirpath), "$(ct)/$(h)"))
            empty!(dirnames)  # an artifact dir is a leaf for enumeration
        end
    end
    return out
end

# Total size in bytes of all files under `path` (best-effort).
function _dir_size(path::AbstractString)::Int
    total = 0
    for (dirpath, _dirnames, filenames) in walkdir(path)
        for name in filenames
            try
                total += filesize(joinpath(dirpath, name))
            catch
            end
        end
    end
    return total
end

# The serialized value's format — extension of the first non-sidecar, non-hidden file.
function _guess_format(artifact_dir::AbstractString)::String
    names = try
        sort!(readdir(artifact_dir))
    catch
        return ""
    end
    for name in names
        (name in _SIDECAR_NAMES || startswith(name, ".")) && continue
        full = joinpath(artifact_dir, name)
        if isfile(full)
            stem, dot, ext = rpartition(name, '.')
            (!isempty(ext) && !isempty(stem)) && return ext
        end
    end
    return ""
end

# Last `.`-split of `s` → (before, ".", after); ("", "", "") when no `.`.
function rpartition(s::AbstractString, c::Char)
    i = findlast(==(c), s)
    i === nothing && return ("", "", "")
    return (s[1:prevind(s, i)], string(c), s[nextind(s, i):end])
end

# The artifact's creation stamp — metadata.toml's `created` if present, else dir mtime.
function _created(artifact_dir::AbstractString)::String
    mpath = joinpath(artifact_dir, "metadata.toml")
    if isfile(mpath)
        try
            created = String(get(TOML.parsefile(mpath), "created", ""))
            !isempty(created) && return created
        catch
        end
    end
    return iso_from_mtime(artifact_dir)
end

"""
    enumerate_artifacts(cache_root) -> Vector{CacheObject}

A `CacheObject` for every produced artifact under `cache_root` (spec-v4: the composition root
hands the `datacache_dir`, so artifacts are `<cachetype>/[<version>/]<hash>` directly under
it). `referenced` is left `nothing` — a composition root resolves it.
"""
function enumerate_artifacts(cache_root::AbstractString)::Vector{CacheObject}
    out = CacheObject[]
    for (artifact_dir, key) in find_produced_artifacts(cache_root)
        local c
        try
            c = read_config(artifact_dir)
        catch
            continue
        end
        version = c.version === nothing ? "" : String(c.version)
        push!(out, CacheObject(
            kind="cached",
            location=abspath(artifact_dir),
            key=key,
            hash=String(c.hash),
            cachetype=String(c.cachetype),
            version=version,
            format=_guess_format(artifact_dir),
            size=_dir_size(artifact_dir),
            created=_created(artifact_dir),
            last_access=last_access(artifact_dir),
        ))
    end
    return out
end

# Remove a path and its sibling completion/lock/tmp markers (best-effort).
function _remove_artifact(location::AbstractString)
    rm(location; force=true, recursive=true)
    for suffix in (".complete", ".lock", ".tmp")
        rm(string(location, suffix); force=true, recursive=true)
    end
end

"""
    delete_object(obj::CacheObject)

Delete a produced artifact directory and its sibling completion/lock/tmp markers. Refuses
anything that is not `kind="cached"` — fetched datasets, `\$data`/`\$repo` and `local_path`
data are never removed by the maintenance surface.
"""
function delete_object(obj::CacheObject)
    obj.kind == "cached" || error("refusing to delete a \"$(obj.kind)\" object at " *
        "$(obj.location) — only produced (cached) artifacts are deletable")
    _remove_artifact(obj.location)
    return nothing
end

"""
    move_object(obj::CacheObject, dest_root) -> String

Move a produced artifact to `dest_root`, preserving its `<cachetype>/[<version>/]<hash>` key
path. Returns the new location. Refuses anything not `kind="cached"`.
"""
function move_object(obj::CacheObject, dest_root::AbstractString)::String
    obj.kind == "cached" || error("refusing to move a \"$(obj.kind)\" object at " *
        "$(obj.location) — only produced (cached) artifacts are movable")
    parts = isempty(obj.version) ? (obj.cachetype, obj.hash) : (obj.cachetype, obj.version, obj.hash)
    dest = joinpath(String(dest_root), parts...)
    d = dirname(dest)
    !isempty(d) && mkpath(d)
    mv(obj.location, dest; force=true)
    for suffix in (".complete", ".lock")
        marker = string(obj.location, suffix)
        ispath(marker) && mv(marker, string(dest, suffix); force=true)
    end
    return dest
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

# Load `[_STORAGE]` from the nearest manifest at `project_root` (empty when none/unreadable)
# — so the same centralized storage settings that drive fetched datasets ($-folder roots,
# `_HOST`/`_SCOPE`/`_PREFIX`) also drive produced artifacts when no `Database` is in scope.
# Mirrors the Python `_load_storage_config`.
function _discover_storage_config(project_root::AbstractString)::Dict{String,Any}
    isempty(project_root) && return Dict{String,Any}()
    for name in ("Datasets.toml", "datasets.toml", "DataManifest.toml", "datamanifest.toml")
        p = joinpath(project_root, name)
        isfile(p) || continue
        try
            s = get(TOML.parsefile(p), "_STORAGE", Dict{String,Any}())
            return s isa AbstractDict ? Dict{String,Any}(s) : Dict{String,Any}()
        catch
            return Dict{String,Any}()
        end
    end
    return Dict{String,Any}()
end

function _cache_context()
    proot = try
        dirname(Base.active_project())
    catch
        pwd()
    end
    return (storage_config=_discover_storage_config(proot), project_root=proot)
end

# Resolve the `cached.toml` path a produced artifact is registered in (the spec's
# "sibling of datasets.toml" convention, with pragmatic fallbacks): an explicit
# `cached_toml` (file, or a directory holding the default) → `<project_root>/cached.toml`
# → `<cwd>/cached.toml`. Mirrors the Python `_locate_cached_toml`.
function _locate_cached_toml(cached_toml, project_root::AbstractString)::String
    if cached_toml !== nothing && !isempty(string(cached_toml))
        ct = String(cached_toml)
        return isdir(ct) ? joinpath(ct, CACHED_INDEX_NAME) : ct
    end
    !isempty(project_root) && return joinpath(project_root, CACHED_INDEX_NAME)
    return joinpath(pwd(), CACHED_INDEX_NAME)
end

# Register a freshly-produced variation into the state file and stamp the depot usage log.
# Reads any existing inventory (so a register ADDS this variation without dropping the rest),
# records the per-instance `storage_path` (the artifact dir) under the recipe `(cachetype,
# version)`, writes canonically, records the file path. Returns the path written.
function _register_produced(state_path::AbstractString;
                            cachetype::AbstractString, hash::AbstractString,
                            storage_path::AbstractString="",
                            ref::AbstractString="", format::AbstractString="",
                            version::AbstractString="")::String
    index = read_index_or_empty(state_path)
    register!(index; cachetype=cachetype, hash=hash, storage_path=storage_path, ref=ref,
              format=format, version=version)
    written = write_index(index, state_path)
    record_path!(written)
    return written
end

# Self-heal the inventory on a cache hit (best-effort, never raises). If this variation is
# missing from the state file (deleted by hand, or never written), re-register it; if present
# but the recipe's `ref` has drifted (the producing function was refactored), refresh it;
# otherwise do nothing. A read-only / malformed state file must never break a hit, so any
# error is swallowed. Mirrors Python `_heal_on_hit`.
function _heal_on_hit(state_path::AbstractString;
                      cachetype::AbstractString, hash::AbstractString, storage_path::AbstractString,
                      ref::AbstractString, format::AbstractString, version::AbstractString)
    try
        index = read_index_or_empty(state_path)
        present = has_instance(index; cachetype=cachetype, version=version, hash=hash)
        ref_current = ref_of(index; cachetype=cachetype, version=version) == ref
        (present && ref_current) && return nothing
        register!(index; cachetype=cachetype, hash=hash, storage_path=storage_path, ref=ref,
                  format=format, version=version)
        record_path!(write_index(index, state_path))
    catch
    end
    return nothing
end

# ── save / load / has (functional API used by the macro and directly) ─────────

"""
    save_cache(data, cachetype, key_table; ext="jls", basename="data", version=nothing,
               cache_dir=nothing, extras=Dict(), name="", ref="", cached_toml=nothing) -> String

Materialize `data` as a produced artifact under `datacache_dir` (or `cache_dir` verbatim) and
write the `config.toml` / `metadata.toml` sidecars. Returns the artifact directory.

The variation is registered in `cached.toml` (resolved from `cached_toml` →
`<project_root>/cached.toml` → `<cwd>/cached.toml`) under its recipe `(cachetype, version)`
with the parameter `hash` + `params`, and that index is stamped into the depot usage log.
`name` is accepted for backward compatibility but no longer affects registration (schema 2
keys recipes by identity, not by name).
"""
function save_cache(data, cachetype::AbstractString, key_table;
                    ext::AbstractString="jls", basename::AbstractString="data",
                    version=nothing, cache_dir=nothing,
                    extras=Dict{String,Any}(),
                    name::AbstractString="", ref::AbstractString="", cached_toml=nothing)::String
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root)
    written_index = _register_produced(
        _locate_cached_toml(cached_toml, ctx.project_root);
        cachetype=cachetype, hash=h, storage_path=dir, ref=ref, format=ext,
        version=(version === nothing ? "" : String(version)))
    materialize(dir) do tmp
        mkpath(tmp)
        _produce_save(data, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root,
                       state_file=written_index)
    end
    return dir
end

"""
    has_cache(cachetype, key_table; version=nothing, cache_dir=nothing) -> Bool

`true` iff a complete, hash-valid produced artifact exists for these parameters.
"""
function has_cache(cachetype::AbstractString, key_table;
                   version=nothing, cache_dir=nothing)::Bool
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root)
    return is_complete(dir) && config_is_valid(dir)
end

"""
    load_cache(cachetype, key_table; ext="jls", basename="data", version=nothing,
               cache_dir=nothing) -> data or nothing

Return the produced artifact for these parameters, or `nothing` on a miss.
"""
function load_cache(cachetype::AbstractString, key_table;
                    ext::AbstractString="jls", basename::AbstractString="data",
                    version=nothing, cache_dir=nothing)
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root)
    (is_complete(dir) && config_is_valid(dir)) || return nothing
    return _produce_load(joinpath(dir, "$(basename).$(ext)"), ext)
end

# The produce-or-load core invoked by the `@cached` wrapper: fast-path load on a hit (with a
# best-effort registry self-heal), otherwise compute + save under the safe-materialization
# primitive, registering the variation in cached.toml first.
function _run_cached(body::Function, cachetype::AbstractString, key_table;
                     ext::AbstractString="jls", basename::AbstractString="data",
                     version=nothing, cache_dir=nothing,
                     extras=Dict{String,Any}(),
                     name::AbstractString="", ref::AbstractString="", cached_toml=nothing)
    ctx = _cache_context()
    h = param_hash(key_table)
    vstr = version === nothing ? "" : String(version)
    dir = cached_dir(cachetype, h; version=version, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root)
    index_path = _locate_cached_toml(cached_toml, ctx.project_root)

    # Search order for a hit: the state-file-recorded artifact dir (where it was actually
    # written — read-first, so a moved artifact is still found), the derived dir (current
    # directive), then any opt-in datacache read pools (another project's produced copy). A hit
    # self-heals the inventory, recording the location it was found at.
    leaf = isempty(vstr) ? joinpath(cachetype, h) : joinpath(cachetype, vstr, h)
    search = String[]
    if isfile(index_path)
        recorded = try
            instance_path_of(read_index(index_path); cachetype=cachetype, version=vstr, hash=h)
        catch
            ""
        end
        if !isempty(recorded)
            rp = isabspath(recorded) ? recorded :
                 joinpath(isempty(ctx.project_root) ? pwd() : ctx.project_root, recorded)
            push!(search, rp)
        end
    end
    push!(search, dir)
    if cache_dir === nothing || isempty(string(cache_dir))
        for pool in datacache_pools(; project_root=ctx.project_root, storage_config=ctx.storage_config)
            push!(search, joinpath(pool, leaf))
        end
    end
    for adir in unique(search)
        art = joinpath(adir, "$(basename).$(ext)")
        if is_complete(adir) && config_is_valid(adir) && isfile(art)
            # spec-v3.2: never written on read for last-access — but the inventory self-heals
            # (best-effort), recording where the artifact was actually found.
            _heal_on_hit(index_path; cachetype=cachetype, hash=h, storage_path=adir, ref=ref,
                         format=ext, version=vstr)
            return _produce_load(art, ext)
        end
    end
    # Miss: register the produced variation in the project's state file (the liveness root for
    # `inspect`) and stamp the usage log, then materialize with the back-pointer.
    written_index = _register_produced(index_path;
        cachetype=cachetype, hash=h, storage_path=dir, ref=ref, format=ext, version=vstr)
    local result
    materialize(dir) do tmp
        mkpath(tmp)
        result = body()
        _produce_save(result, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root,
                       state_file=written_index)
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
            [version="v3"] function fn(; kw…) … end

Wrap a **keyword-only** function with transparent produce-or-load disk caching (spec-v4
`cache-produce`).

- `cachetype` (String literal, optional): the artifact namespace. **Defaults to the producing
  function's importable name `Module.func`** so distinct functions never collide; pass an
  explicit value for a stable hand-chosen name or to group several functions under one
  namespace.
- `key` (required): a callable receiving a NamedTuple of the function's hash-affecting
  keyword arguments (every declared kwarg except `_`-prefixed runtime knobs) and returning
  the **key table** (a NamedTuple/Dict). Its canonical-JSON SHA-256 is the parameter hash.
  Hash inputs are strings/integers/booleans/**finite floats**/arrays/objects of those
  (spec-v3.1); finite floats serialize via the normative Python `json.dumps` form
  (`1.0`→"1.0"). `NaN`/`±Inf` and nulls raise.
- `ext` (default `"jls"`): artifact serialization format. `jls` (stdlib `Serialization`) is
  the zero-dependency built-in self-saver; register others (e.g. the spec's RECOMMENDED Julia
  default `jld2`) with `DataManifest.Cache.register_format!`.
- `basename` (default `"data"`), `version` (optional recipe/code version → a path segment +
  part of the recipe identity, not in the hash).
- `name` (String literal, optional): accepted for backward compatibility; schema-2 recipes
  are keyed by `(cachetype, version)` identity, not by name, so it no longer affects
  registration.

The artifact lands under the manifest's **`datacache_dir`** (spec-v4; default `<repo>/cached`):
`<datacache_dir>/<cachetype>/[<version>/]<hash>`. The wrapper injects a `cached::Bool=true`
escape hatch (`cached=false` runs the body with no disk I/O and no registration). A kwarg
named exactly `_metadata_extras` (NamedTuple/Dict/`nothing`) is an audit-only channel merged
into `metadata.toml` without affecting the hash; any other `_`-prefixed kwarg is a runtime
knob excluded from the hash but visible in the body. A declared `cached_toml` kwarg, if
present, overrides the index path; a declared `cache_dir` kwarg overrides the artifact
location verbatim (the experiment-folder workflow).

**Registration (spec-v4 `inspect`).** On a **produce** (miss) the variation is registered in
the project's `cached.toml` (the produced-dataset registry / liveness root) under its recipe
`(cachetype, version)` with the parameter `hash` + `params`, `ref = "<module>:<function>"`,
and `format`; that index path is stamped into the depot usage log and the `metadata.toml`
`[origin].cached_toml` back-pointer names it. The index defaults to
`<project_root>/cached.toml` (a `cached_toml` kwarg overrides it). A cache **hit**
(spec-v3.2) **writes nothing on read** for last-access, but **self-heals the registry**
(best-effort): if the index lost this variation (deleted by hand, or never written) or its
`ref` drifted, the hit re-registers it, so the index rebuilds by re-running.

**Produced datasets are keyword-only** — a function with positional arguments is rejected
(a positional list has no stable name→value identity to hash).

> **Note (spec-v3.7 conflict guard).** The spec's same-process `(cachetype, version)`
> conflict guard is a SHOULD and is **intentionally omitted here**: Julia's top-level
> decoration runs during precompilation rather than the user's session, so a process-local
> recipe registry would be an unreliable basis for the check (the spec explicitly permits
> narrowing or omitting it for such languages).
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
    regname = nothing
    for kw in kw_args
        Meta.isexpr(kw, :(=)) || error("@cached: expected `name=value`, got $(kw)")
        kwname, val = kw.args
        if kwname === :cachetype
            isa(val, String) || error("@cached: `cachetype` must be a String literal")
            cachetype = val
        elseif kwname === :key
            keyfn = val
        elseif kwname === :ext
            isa(val, String) || error("@cached: `ext` must be a String literal")
            ext = val
        elseif kwname === :basename
            isa(val, String) || error("@cached: `basename` must be a String literal")
            basename = val
        elseif kwname === :version
            isa(val, String) || error("@cached: `version` must be a String literal")
            version = val
        elseif kwname === :name
            isa(val, String) || error("@cached: `name` must be a String literal")
            regname = val
        else
            error("@cached: unknown argument `$kwname`. Expected `cachetype`, `key`, `ext`, `basename`, `version`, or `name`.")
        end
    end
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
    has_cached_toml = :cached_toml in kw_names

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
    ct_expr = has_cached_toml ? :(cached_toml) : :(nothing)
    _ext = ext === nothing ? "jls" : ext
    _basename = basename === nothing ? "data" : basename
    _version = version === nothing ? nothing : version
    # cachetype default (spec-v4): the producing function's importable name `Module.func`.
    _cachetype = cachetype === nothing ? "$(__module__).$(fname)" : cachetype
    # cached.toml registry name (default: the function name) and producing-function ref.
    _name = regname === nothing ? string(fname) : regname
    _ref = "$(__module__):$(fname)"
    _run = GlobalRef(@__MODULE__, :_run_cached)

    body_fn = Expr(:(->), Expr(:tuple), body)

    wrapper = quote
        _body_fn = $body_fn
        if !cached
            return _body_fn()
        end
        _kt = $(keyfn)($nt_args)
        return $_run(_body_fn, $_cachetype, _kt;
            ext=$_ext, basename=$_basename, version=$_version,
            cache_dir=$cd_expr, extras=$build_extras,
            name=$_name, ref=$_ref, cached_toml=$ct_expr)
    end

    return esc(Expr(:function, new_sig, wrapper))
end

end # module Cache

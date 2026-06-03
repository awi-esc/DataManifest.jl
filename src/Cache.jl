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
using ..Storage: store_dir, selector_root, content_prefix, content_scope, project_id,
    is_complete, marker_path, lock_path, tmp_path, user_state_dir
using ..PipeLines: materialize

export @cached, param_hash, cache_key, cached_dir,
    save_cache, load_cache, has_cache, read_config, config_is_valid, register_format!,
    # cached.toml index (spec-v3 produced-dataset registry)
    CachedIndex, read_index, read_index_or_empty, register!, index_keys, write_index,
    CACHED_INDEX_NAME,
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

# ── The `cached.toml` index (spec-v3 produced-dataset registry) ───────────────
#
# `cached.toml` is to produced datasets what `datasets.toml` is to fetched ones: a
# registry, sibling to the manifest by default, that lists each produced dataset by its
# PORTABLE key (`cachetype` + parameter `hash`) — never an absolute path — so it stays
# relocatable. It carries its own `[_META].schema = 1` (+ an optional declared `project`)
# and is the liveness root set for the `inspect` maintenance surface. One table per
# produced dataset records `cachetype`, `hash`, `ref`, `format`, `store`, and (spec-v3,
# when non-empty) `project` and recipe `version`. Mirrors the Python `cache/_index.py`.

const CACHED_INDEX_NAME = "cached.toml"
const CACHED_INDEX_SCHEMA = 1

"""
    CachedIndex(; entries=Dict(), path="", project="")

In-memory view of a `cached.toml`: `entries` is a `name → Dict` map of produced datasets,
`path` the file it was read from / will be written to, `project` the optional declared
project id (`[_META].project`).
"""
mutable struct CachedIndex
    entries::Dict{String,Any}
    path::String
    project::String
end
CachedIndex(; entries=Dict{String,Any}(), path::AbstractString="", project::AbstractString="") =
    CachedIndex(Dict{String,Any}(entries), String(path), String(project))

# Normalize `path` to a cached.toml file path (accepts a directory holding the default).
function _index_resolve_path(path::AbstractString)::String
    p = String(path)
    endswith(p, CACHED_INDEX_NAME) && return p
    isdir(p) && return joinpath(p, CACHED_INDEX_NAME)
    return p
end

"""
    read_index(path) -> CachedIndex

Read a `cached.toml` from `path` (a file, or a directory holding the default-named index).
The entries are every root table except the `[_META]` block.
"""
function read_index(path::AbstractString)::CachedIndex
    target = _index_resolve_path(path)
    t = TOML.parsefile(target)
    meta = get(t, "_META", Dict{String,Any}())
    entries = Dict{String,Any}(k => v for (k, v) in t if k != "_META")
    return CachedIndex(entries=entries, path=target, project=String(get(meta, "project", "")))
end

"""
    read_index_or_empty(path) -> CachedIndex

Read the index at `path`, or return an empty one bound to that path when it does not exist.
"""
function read_index_or_empty(path::AbstractString)::CachedIndex
    target = _index_resolve_path(path)
    isfile(target) ? read_index(target) : CachedIndex(path=target)
end

"""
    register!(index, name; cachetype, hash, ref="", format="", store="\$cache",
              project="", version="")

Add or update the produced dataset `name` (keyed by portable name). Identity is the
portable `(cachetype, hash)` pair, never an absolute path. `project` (the artifact's
project-id scope) and `version` (the optional recipe version) are recorded only when
non-empty, so a plain entry keeps the original five fields. Re-registering overwrites.
"""
function register!(index::CachedIndex, name::AbstractString;
                   cachetype::AbstractString, hash::AbstractString,
                   ref::AbstractString="", format::AbstractString="",
                   store::AbstractString="\$cache",
                   project::AbstractString="", version::AbstractString="")
    entry = Dict{String,Any}(
        "cachetype" => String(cachetype),
        "hash" => String(hash),
        "ref" => String(ref),
        "format" => String(format),
        "store" => String(store),
    )
    !isempty(project) && (entry["project"] = String(project))
    !isempty(version) && (entry["version"] = String(version))
    index.entries[String(name)] = entry
    return index
end

"""
    index_keys(index) -> Set{String}

The set of portable cache keys `"<cachetype>/<hash>"` this index roots — the produced
live-key contribution to `inspect`'s `referenced` determination.
"""
function index_keys(index::CachedIndex)::Set{String}
    out = Set{String}()
    for (_, entry) in index.entries
        entry isa AbstractDict || continue
        ct = String(get(entry, "cachetype", ""))
        h = String(get(entry, "hash", ""))
        (!isempty(ct) && !isempty(h)) && push!(out, "$(ct)/$(h)")
    end
    return out
end

function _index_to_dict(index::CachedIndex)::Dict{String,Any}
    meta = Dict{String,Any}("schema" => CACHED_INDEX_SCHEMA)
    !isempty(index.project) && (meta["project"] = index.project)
    out = Dict{String,Any}("_META" => meta)
    for (name, entry) in index.entries
        out[name] = entry isa AbstractDict ? Dict{String,Any}(entry) : entry
    end
    return out
end

"""
    write_index(index, path="") -> String

Write the index to `path` (or its loaded `path`), canonically (lexicographically) ordered
like the manifest writer. Returns the path written.
"""
function write_index(index::CachedIndex, path::AbstractString="")::String
    target = isempty(path) ? index.path : path
    isempty(target) && error("write_index: no path given and CachedIndex has no loaded path")
    target = _index_resolve_path(target)
    dir = dirname(target)
    !isempty(dir) && mkpath(dir)
    open(target, "w") do io
        TOML.print(io, _index_to_dict(index); sorted=true)
    end
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
name (fetched). `hash`/`cachetype`/`version` are produced-artifact identity; `scope`,
`format`, `size`, `created`, `last_access` are inspectable fields; `referenced` is
`true`/`false` once a composition root resolves reachability, `nothing` while unknown.
"""
Base.@kwdef mutable struct CacheObject
    kind::String
    location::String
    key::String = ""
    hash::String = ""
    cachetype::String = ""
    version::String = ""
    scope::String = ""
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

# Scope segment(s) of `artifact_dir` relative to `cache_root`: whatever path components sit
# between the content prefix and the trailing `<cachetype>/[<version>/]<hash>` key.
function _scope_of(artifact_dir::AbstractString, cache_root::AbstractString;
                   prefix::AbstractString, version::AbstractString)::String
    rel = relpath(artifact_dir, cache_root)
    parts = String[p for p in split(rel, ('/', '\\')) if !(p in ("", "."))]
    pp = String[p for p in split(prefix, '/') if !isempty(p)]
    if length(parts) >= length(pp) && parts[1:length(pp)] == pp
        parts = parts[length(pp)+1:end]
    end
    tail = isempty(version) ? 2 : 3  # cachetype[/version]/hash
    scope_parts = parts[1:max(0, length(parts) - tail)]
    return join(scope_parts, "/")
end

"""
    enumerate_artifacts(cache_root; prefix="cached") -> Vector{CacheObject}

A `CacheObject` for every produced artifact under `cache_root`. `prefix` is the content
prefix produced artifacts compose under (default `"cached"`), stripped when deriving each
object's `scope`. `referenced` is left `nothing` — a composition root resolves it.
"""
function enumerate_artifacts(cache_root::AbstractString; prefix::AbstractString="cached")::Vector{CacheObject}
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
            scope=_scope_of(artifact_dir, cache_root; prefix=prefix, version=version),
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

function _cache_context()
    proot = try
        dirname(Base.active_project())
    catch
        pwd()
    end
    return (storage_config=Dict{String,Any}(), project_root=proot, declared_project="")
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

# Register a freshly-produced artifact into its cached.toml and stamp the depot usage log.
# Reads any existing index (so one entry is added/updated without dropping the rest),
# registers the portable key, writes canonically, records the index path. Returns the path.
function _register_produced(cached_toml_path::AbstractString, name::AbstractString;
                            cachetype::AbstractString, hash::AbstractString,
                            ref::AbstractString="", format::AbstractString="",
                            store::AbstractString="\$cache",
                            project::AbstractString="", version::AbstractString="")::String
    index = read_index_or_empty(cached_toml_path)
    register!(index, name; cachetype=cachetype, hash=hash, ref=ref, format=format,
              store=store, project=project, version=version)
    written = write_index(index, cached_toml_path)
    record_path!(written)
    return written
end

# ── save / load / has (functional API used by the macro and directly) ─────────

"""
    save_cache(data, cachetype, key_table; ext="jls", basename="data", version=nothing,
               store="\$cache", cache_dir=nothing, extras=Dict(),
               name="", ref="", cached_toml=nothing) -> String

Materialize `data` as a produced artifact at the composed cache directory and write the
`config.toml` / `metadata.toml` sidecars. Returns the artifact directory.

When a non-empty `name` is given, the artifact is also registered in `cached.toml` (resolved
from `cached_toml` → `<project_root>/cached.toml` → `<cwd>/cached.toml`) with `ref`/`format`/
`store`/`project`/`version`, and that index is stamped into the depot usage log — mirroring
the `@cached` macro. With an empty `name` (the default) registration is skipped.
"""
function save_cache(data, cachetype::AbstractString, key_table;
                    ext::AbstractString="jls", basename::AbstractString="data",
                    version=nothing, store::AbstractString="\$cache", cache_dir=nothing,
                    extras=Dict{String,Any}(),
                    name::AbstractString="", ref::AbstractString="", cached_toml=nothing)::String
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    # Register in cached.toml when a portable `name` is given (the @cached macro always
    # passes the function name); record the index back-pointer in metadata.toml.
    written_index = ""
    if !isempty(name)
        written_index = _register_produced(
            _locate_cached_toml(cached_toml, ctx.project_root), name;
            cachetype=cachetype, hash=h, ref=ref, format=ext, store=store,
            project=project_id(ctx.project_root; declared=ctx.declared_project),
            version=(version === nothing ? "" : String(version)))
    end
    materialize(dir) do tmp
        mkpath(tmp)
        _produce_save(data, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root,
                       cached_toml=(isempty(written_index) ? nothing : written_index))
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
                     extras=Dict{String,Any}(),
                     name::AbstractString="", ref::AbstractString="", cached_toml=nothing)
    ctx = _cache_context()
    h = param_hash(key_table)
    dir = cached_dir(cachetype, h; version=version, store=store, cache_dir=cache_dir,
                     storage_config=ctx.storage_config, project_root=ctx.project_root,
                     declared_project=ctx.declared_project)
    artifact = joinpath(dir, "$(basename).$(ext)")
    if is_complete(dir) && config_is_valid(dir)
        return _produce_load(artifact, ext)     # spec-v3.2: never written on read
    end
    # Miss: register the produced artifact in the project's cached.toml (the liveness root
    # for `inspect`) and stamp the usage log, then materialize with the back-pointer.
    written_index = ""
    if !isempty(name)
        written_index = _register_produced(
            _locate_cached_toml(cached_toml, ctx.project_root), name;
            cachetype=cachetype, hash=h, ref=ref, format=ext, store=store,
            project=project_id(ctx.project_root; declared=ctx.declared_project),
            version=(version === nothing ? "" : String(version)))
    end
    local result
    materialize(dir) do tmp
        mkpath(tmp)
        result = body()
        _produce_save(result, joinpath(tmp, "$(basename).$(ext)"), ext)
        write_config(tmp, key_table, cachetype; version=version, hash=h)
        write_metadata(tmp; cachetype=cachetype, extras=extras, project_root=ctx.project_root,
                       cached_toml=(isempty(written_index) ? nothing : written_index))
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
  Hash inputs are strings/integers/booleans/**finite floats**/arrays/objects of those
  (spec-v3.1); finite floats serialize via the normative Python `json.dumps` form
  (`1.0`→"1.0"). `NaN`/`±Inf` and nulls raise.
- `ext` (default `"jls"`): artifact serialization format. `jls` (stdlib `Serialization`) is
  built in; register others with `DataManifest.Cache.register_format!`.
- `basename` (default `"data"`), `version` (optional recipe/code version → a path segment,
  not in the hash), `store` (default `"\$cache"`).
- `name` (String literal, optional): the portable registry name listed in `cached.toml`
  (default: the wrapped function's name).

The wrapper injects a `cached::Bool=true` escape hatch (`cached=false` runs the body with no
disk I/O and no registration). A kwarg named exactly `_metadata_extras`
(NamedTuple/Dict/`nothing`) is an audit-only channel merged into `metadata.toml` without
affecting the hash; any other `_`-prefixed kwarg is a runtime knob excluded from the hash but
visible in the body. A declared `cached_toml` kwarg, if present, overrides the index path
(see below); a declared `cache_dir` kwarg overrides the artifact location verbatim.

**Registration (spec-v3 `inspect`).** On a **produce** (miss) the artifact is registered in
the project's `cached.toml` (the produced-dataset registry / liveness root) by its portable
key — `cachetype`, `hash`, `ref = "<module>:<function>"`, `format`, `store`, the project-id
`project` scope, and the recipe `version` when set — and that index path is stamped into the
depot usage log; the `metadata.toml` `[origin].cached_toml` back-pointer names it. The index
defaults to `<project_root>/cached.toml` (a `cached_toml` kwarg overrides it). A cache **hit**
re-registers nothing and (spec-v3.2) **writes nothing on read** — last-access is read from the
filesystem at inspect time, never recorded by the reader.

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
        elseif kwname === :store
            isa(val, String) || error("@cached: `store` must be a String literal")
            store = val
        elseif kwname === :name
            isa(val, String) || error("@cached: `name` must be a String literal")
            regname = val
        else
            error("@cached: unknown argument `$kwname`. Expected `cachetype`, `key`, `ext`, `basename`, `version`, `store`, or `name`.")
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
    _store = store === nothing ? "\$cache" : store
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
        return $_run(_body_fn, $cachetype, _kt;
            ext=$_ext, basename=$_basename, version=$_version, store=$_store,
            cache_dir=$cd_expr, extras=$build_extras,
            name=$_name, ref=$_ref, cached_toml=$ct_expr)
    end

    return esc(Expr(:function, new_sig, wrapper))
end

end # module Cache

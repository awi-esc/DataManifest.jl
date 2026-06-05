"""
    Storage

Pure resolver for the spec-v4 storage model — **two folders, local by default**. Storage is
just *where fetched datasets go* and *where the produced cache goes*; both are set in
`[_STORAGE]` and default to repo-relative `datasets/` and `cached/`:

    [_STORAGE]
    datasets_dir  = "datasets"     # fetched: <datasets_dir>/<key>
    datacache_dir = "cached"       # produced: <datacache_dir>/<cachetype>/[<version>/]<hash>/

There is **no scope, no prefix, no derived/app name** — the folder you set *is* the location.
A relative value is relative to the project root (`\$repo`); absolute / `~` / `\$symbol`-rooted
paths are used as written.

A path may interpolate `\$`-**symbols**. Predefined (bare platformdirs — no app name appended):

- `\$user_data_dir`  → `platformdirs.user_data_dir()` (persistent)
- `\$user_cache_dir` → `platformdirs.user_cache_dir()` (reclaimable)
- `\$repo`           → the project root (manifest directory; base for relative paths)

Any other bare `[_STORAGE]` key is a **user-defined symbol**, optionally host-specific via
`[_STORAGE._HOST."<glob>"]`. Resolution ladder (first match wins): `DATAMANIFEST_<NAME>` env →
`[_STORAGE._HOST.<glob>].<name>` → base `[_STORAGE].<name>` → (predefined) platformdirs /
project-root default. The two fields are overridable by exactly two env vars,
`DATAMANIFEST_DATASETS_DIR` / `DATAMANIFEST_DATACACHE_DIR`.

The module is intentionally pure: given explicit `env` / `host` arguments it is deterministic
and testable. Linux is the primary verified target; macOS / Windows follow the same
`platformdirs` conventions.
"""
module Storage

using TOML
using SHA

export expand_path_expr, resolve_symbol, datasets_dir, datacache_dir, dataset_storage_path,
    datasets_pools, datacache_pools, user_state_dir, user_symbols, PREDEFINED_SYMBOLS,
    RESERVED_STORAGE_KEYS, POOL_DEFAULTS, legacy_data_root

"""Predefined `\$`-symbols (platform/project-resolved; never user-redefinable shadows)."""
const PREDEFINED_SYMBOLS = ("user_data_dir", "user_cache_dir", "repo")

"""Reserved `[_STORAGE]` keys that are NOT user-defined symbols (the folder fields, the read-pool
list fields, and `_HOST`)."""
const RESERVED_STORAGE_KEYS = ("datasets_dir", "datacache_dir",
                               "datasets_pools", "datacache_pools", "_HOST")

"""Built-in default field values (relative ⇒ repo-relative)."""
const _DEFAULT_DATASETS_DIR = "datasets"
const _DEFAULT_DATACACHE_DIR = "cached"

# --- glob matching (`*`, `?`) for `_HOST` patterns ---------------------------

const _GLOB_SPECIAL = Set(['.', '\\', '+', '-', '^', '$', '|', '(', ')', '[', ']', '{', '}'])

"""
    _glob_match(pattern, s) -> Bool

Match `s` against a shell-style glob `pattern` (`*` any run, `?` single char); whole-string.
"""
function _glob_match(pattern::AbstractString, s::AbstractString)::Bool
    buf = IOBuffer()
    print(buf, "^")
    for c in pattern
        if c == '*'
            print(buf, ".*")
        elseif c == '?'
            print(buf, ".")
        elseif c in _GLOB_SPECIAL
            print(buf, '\\', c)
        else
            print(buf, c)
        end
    end
    print(buf, "\$")
    return occursin(Regex(String(take!(buf))), s)
end

# --- platformdirs-equivalent BARE dirs (no app name, spec-v4) ----------------

"""
    user_data_dir(env=ENV) -> String

`platformdirs.user_data_dir()` — the **bare** user data dir (no `datamanifest`/app segment).
Linux: `\$XDG_DATA_HOME` (default `~/.local/share`). macOS: `~/Library/Application Support`.
Windows: `%LOCALAPPDATA%`.
"""
function user_data_dir(env=ENV)::String
    if Sys.iswindows()
        return get(env, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Application Support")
    else
        return get(env, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
    end
end

"""
    user_cache_dir(env=ENV) -> String

`platformdirs.user_cache_dir()` — the **bare** user cache dir. Linux: `\$XDG_CACHE_HOME`
(default `~/.cache`). macOS: `~/Library/Caches`. Windows: `%LOCALAPPDATA%`.
"""
function user_cache_dir(env=ENV)::String
    if Sys.iswindows()
        return get(env, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Caches")
    else
        return get(env, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
    end
end

"""
    user_state_dir(env=ENV) -> String

`platformdirs.user_state_dir("datamanifest")` — the per-user machine-local **state** dir
(where the cache layer's `usage.toml` lives). Tool bookkeeping, not addressed data.
"""
function user_state_dir(env=ENV)::String
    if Sys.iswindows()
        base = get(env, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
        return joinpath(base, "datamanifest", "datamanifest")
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Application Support", "datamanifest")
    else
        base = get(env, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state"))
        return joinpath(base, "datamanifest")
    end
end

"""
    legacy_data_root(env=ENV) -> String

The pre-v1.1 default datasets folder — `\$XDG_CACHE_HOME/Datasets` (default `~/.cache/Datasets`).
A **read-only** back-compat probe location, checked last so old downloads still resolve.
"""
function legacy_data_root(env=ENV)::String
    base = get(env, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
    return joinpath(base, "Datasets")
end

# --- symbol discovery & resolution -------------------------------------------

"""
    user_symbols(storage_config) -> Vector{String}

The user-defined symbol names in `[_STORAGE]` (every bare key that is not a reserved field /
`_HOST`), including those that appear only under `_HOST` patterns. Sorted.
"""
function user_symbols(storage_config::AbstractDict)::Vector{String}
    names = Set{String}()
    for (k, _) in storage_config
        ks = String(k)
        ks in RESERVED_STORAGE_KEYS && continue
        push!(names, ks)
    end
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for (_, entry) in hosts
            entry isa AbstractDict || continue
            for (kk, _) in entry
                String(kk) in RESERVED_STORAGE_KEYS && continue
                push!(names, String(kk))
            end
        end
    end
    return sort!(collect(names))
end

# The raw value for a symbol/field `name` from the resolution ladder rungs 1-3 (env, _HOST,
# base), or `nothing` when none applies. The value is a path expression (not yet expanded).
function _ladder_value(name::AbstractString, storage_config::AbstractDict, env, host)
    envkey = "DATAMANIFEST_$(uppercase(name))"
    haskey(env, envkey) && !isempty(env[envkey]) && return String(env[envkey])
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for pat in sort(collect(keys(hosts)))  # deterministic
            entry = hosts[pat]
            if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, name)
                return String(entry[name])
            end
        end
    end
    (haskey(storage_config, name) && !isempty(string(storage_config[name]))) &&
        return String(storage_config[name])
    return nothing
end

"""
    resolve_symbol(name; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

Resolve a `\$`-symbol `name` to a path. Ladder: `DATAMANIFEST_<NAME>` env →
`[_STORAGE._HOST.<glob>].<name>` → base `[_STORAGE].<name>` → predefined default
(`user_data_dir` / `user_cache_dir` / `repo`). A rung-1/2/3 value is itself a path expression
(may reference other symbols). An undefined non-predefined symbol is an error.
"""
function resolve_symbol(name::AbstractString; project_root::AbstractString="",
                        storage_config::AbstractDict=Dict{String,Any}(), env=ENV,
                        host::AbstractString=gethostname(),
                        _seen::Set{String}=Set{String}())::String
    name = String(name)
    name in _seen && error("Storage symbol \$$name references itself (cycle) in [_STORAGE].")
    seen2 = union(_seen, Set([name]))
    raw = _ladder_value(name, storage_config, env, host)
    if raw !== nothing
        p = expand_path_expr(raw; project_root=project_root, storage_config=storage_config,
                             env=env, host=host, _seen=seen2)
        # `repo` resolves a relative override against the project root.
        return (name == "repo" && !isabspath(p) && !isempty(project_root)) ?
            joinpath(String(project_root), p) : p
    end
    name == "user_data_dir" && return user_data_dir(env)
    name == "user_cache_dir" && return user_cache_dir(env)
    name == "repo" && return isempty(project_root) ? pwd() : String(project_root)
    error("Unknown storage symbol \$$name: not predefined " *
          "(user_data_dir/user_cache_dir/repo) and not defined in [_STORAGE].")
end

# --- path-expression expansion -----------------------------------------------

"""
    expand_path_expr(expr; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

Expand a path expression: `\$NAME` / `\${NAME}` → the symbol `NAME` (predefined or
`[_STORAGE]`-defined) if known, else the environment variable `NAME`, else verbatim; a leading
`~` → home.
"""
function expand_path_expr(expr::AbstractString;
                          project_root::AbstractString="",
                          storage_config::AbstractDict=Dict{String,Any}(),
                          env=ENV, host::AbstractString=gethostname(),
                          _seen::Set{String}=Set{String}())::String
    s = String(expr)
    known = Set{String}(PREDEFINED_SYMBOLS)
    union!(known, user_symbols(storage_config))

    resolve(name::AbstractString, whole::AbstractString) = begin
        nm = String(name)
        if nm in known
            return resolve_symbol(nm; project_root=project_root, storage_config=storage_config,
                                  env=env, host=host, _seen=_seen)
        elseif haskey(env, nm)
            return String(env[nm])
        else
            return String(whole)
        end
    end

    s = replace(s, r"\$\{[A-Za-z_][A-Za-z0-9_]*\}" => m -> resolve(m[3:end-1], m))
    s = replace(s, r"\$[A-Za-z_][A-Za-z0-9_]*" => m -> resolve(m[2:end], m))
    return expanduser(s)
end

# --- the two folder fields ---------------------------------------------------

# Resolve a storage field (`datasets_dir` / `datacache_dir`) to an absolute path. Ladder:
# DATAMANIFEST_<FIELD> env → _HOST → base [_STORAGE] → built-in default; then expand symbols
# and resolve a relative result against the project root.
function _field_dir(field::AbstractString, default::AbstractString;
                    project_root::AbstractString, storage_config::AbstractDict, env, host)::String
    raw = _ladder_value(field, storage_config, env, host)
    raw === nothing && (raw = default)
    p = expand_path_expr(raw; project_root=project_root, storage_config=storage_config,
                         env=env, host=host)
    return isabspath(p) ? p :
        (isempty(project_root) ? p : joinpath(String(project_root), p))
end

"""
    datasets_dir(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

The resolved fetched-datasets folder (default `"datasets"` ⇒ `<project_root>/datasets`).
Overridable by `DATAMANIFEST_DATASETS_DIR`, a `_HOST` entry, or `[_STORAGE].datasets_dir`.
"""
datasets_dir(; project_root::AbstractString="", storage_config::AbstractDict=Dict{String,Any}(),
             env=ENV, host::AbstractString=gethostname())::String =
    _field_dir("datasets_dir", _DEFAULT_DATASETS_DIR;
               project_root=project_root, storage_config=storage_config, env=env, host=host)

"""
    datacache_dir(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

The resolved produced-cache folder (default `"cached"` ⇒ `<project_root>/cached`). Overridable
by `DATAMANIFEST_DATACACHE_DIR`, a `_HOST` entry, or `[_STORAGE].datacache_dir`.
"""
datacache_dir(; project_root::AbstractString="", storage_config::AbstractDict=Dict{String,Any}(),
              env=ENV, host::AbstractString=gethostname())::String =
    _field_dir("datacache_dir", _DEFAULT_DATACACHE_DIR;
               project_root=project_root, storage_config=storage_config, env=env, host=host)

# ── Read pools (Python-parity; ahead of the spec) ─────────────────────────────
#
# A **read pool** is an extra read-only location probed for an already-present object before
# fetching/recomputing, so a dataset/artifact another project already has on this machine is
# reused in place (never written to; new writes still follow the directive). Configured via
# `[_STORAGE].datasets_pools` / `[_STORAGE].datacache_pools` — a LIST of path expressions,
# host-composable via `_HOST`, or the env var `DATAMANIFEST_DATASETS_POOLS` /
# `DATAMANIFEST_DATACACHE_POOLS` (`pathsep`-separated). Datasets default to well-known
# locations when undefined; datacache is opt-in (undefined ⇒ none). An explicit empty list
# disables them.

"""Built-in fetched-dataset read pools, probed when `[_STORAGE].datasets_pools` is undefined."""
const POOL_DEFAULTS = ("\$user_data_dir/datamanifest/datasets", "~/.cache/Datasets")

_pathsep() = Sys.iswindows() ? ';' : ':'

# The raw `*_pools` value (a Vector of path expressions, or `nothing` when undefined) via the
# env → `_HOST` glob → base `[_STORAGE]` ladder.
function _pools_raw(field::AbstractString, storage_config::AbstractDict, env, host)
    envkey = "DATAMANIFEST_$(uppercase(field))"
    if haskey(env, envkey)
        return String[p for p in split(String(env[envkey]), _pathsep()) if !isempty(p)]
    end
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for pat in sort(collect(keys(hosts)))
            entry = hosts[pat]
            if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, field)
                v = entry[field]
                return v isa AbstractVector ? String[String(x) for x in v] : String[String(v)]
            end
        end
    end
    if haskey(storage_config, field)
        v = storage_config[field]
        return v isa AbstractVector ? String[String(x) for x in v] : String[String(v)]
    end
    return nothing
end

function _resolve_pools(field::AbstractString, defaults; project_root, storage_config, env, host)
    raw = _pools_raw(field, storage_config, env, host)
    exprs = raw === nothing ? collect(String, defaults) : raw
    out = String[]
    for expr in exprs
        p = try
            expand_path_expr(expr; project_root=project_root, storage_config=storage_config,
                             env=env, host=host)
        catch
            continue   # a malformed pool entry is skipped
        end
        ap = abspath(p)
        ap in out || push!(out, ap)
    end
    return out
end

"""
    datasets_pools(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> Vector{String}

Resolved absolute **fetched-dataset read pools** — extra read-only locations probed for an
already-present `<pool>/<key>` before downloading. `[_STORAGE].datasets_pools` (host-composable
via `_HOST`, or `DATAMANIFEST_DATASETS_POOLS`) gives them; when **undefined** the built-in
[`POOL_DEFAULTS`] apply; an explicit empty list disables them. Each entry is a path expression.
"""
datasets_pools(; project_root::AbstractString="", storage_config::AbstractDict=Dict{String,Any}(),
               env=ENV, host::AbstractString=gethostname())::Vector{String} =
    _resolve_pools("datasets_pools", POOL_DEFAULTS; project_root=project_root,
                   storage_config=storage_config, env=env, host=host)

"""
    datacache_pools(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> Vector{String}

Resolved absolute **produced-artifact read pools** — extra read-only locations probed for an
already-produced `<pool>/<cachetype>[/<version>]/<hash>` before recomputing.
`[_STORAGE].datacache_pools` (host-composable via `_HOST`, or `DATAMANIFEST_DATACACHE_POOLS`);
**opt-in** — undefined means *no* pools (produced artifacts carry no content checksum, only
their identity + `config.toml` validation). An empty list is likewise none.
"""
datacache_pools(; project_root::AbstractString="", storage_config::AbstractDict=Dict{String,Any}(),
                env=ENV, host::AbstractString=gethostname())::Vector{String} =
    _resolve_pools("datacache_pools", String[]; project_root=project_root,
                   storage_config=storage_config, env=env, host=host)

"""
    dataset_storage_path(storage_path, key; project_root="", storage_config=Dict(),
                         env=ENV, host=gethostname(), datasets_folder="") -> String

Resolve a dataset's on-disk path (spec-v4). `storage_path` is the per-dataset field (a path
expression); when empty it defaults to `\$datasets_dir/\$key`. `\$datasets_dir` resolves to the
fetched-datasets folder (or `datasets_folder` when that explicit override is given), `\$key` to
the dataset key; other `\$`-symbols, env vars, and `~` expand too. A relative result resolves
against the project root.

Containing `\$key` ⇒ a tool-managed keyed location; an exact path without `\$key` ⇒ a
user-managed location used verbatim (maintenance never touches it).
"""
function dataset_storage_path(storage_path::AbstractString, key::AbstractString;
                              project_root::AbstractString="",
                              storage_config::AbstractDict=Dict{String,Any}(),
                              env=ENV, host::AbstractString=gethostname(),
                              datasets_folder::AbstractString="")::String
    expr = isempty(storage_path) ? "\$datasets_dir/\$key" : String(storage_path)
    ddir = isempty(datasets_folder) ?
        datasets_dir(; project_root=project_root, storage_config=storage_config,
                     env=env, host=host) : String(datasets_folder)
    expr = replace(expr, "\${datasets_dir}" => ddir, "\$datasets_dir" => ddir)
    expr = replace(expr, "\${key}" => String(key), "\$key" => String(key))
    p = expand_path_expr(expr; project_root=project_root, storage_config=storage_config,
                         env=env, host=host)
    return isabspath(p) ? p :
        (isempty(project_root) ? p : joinpath(String(project_root), p))
end

# --- safe-materialization path helpers ---------------------------------------

export tmp_path, lock_path, marker_path, is_complete

"""
    tmp_path(target) -> String

Sibling staging path (`<target>.tmp`) a fetcher populates before the atomic publish.
"""
tmp_path(target::AbstractString)::String = string(target, ".tmp")

"""
    lock_path(target) -> String

Sibling pidfile-lock path (`<target>.lock`) held while a dataset is being materialized.
"""
lock_path(target::AbstractString)::String = string(target, ".lock")

"""
    marker_path(target) -> String

Completion-marker path for `target`: `<target>/.complete` when `target` is a directory,
`<target>.complete` (a sibling) otherwise.
"""
marker_path(target::AbstractString)::String =
    isdir(target) ? joinpath(String(target), ".complete") : string(target, ".complete")

"""
    is_complete(target) -> Bool

`true` iff `target`'s completion marker exists. Readers MUST treat a missing marker as
absent even when `target` itself is present.
"""
is_complete(target::AbstractString)::Bool = isfile(marker_path(target))

end # module Storage

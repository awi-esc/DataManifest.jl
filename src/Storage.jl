"""
    Storage

Pure resolver for the spec-v5 storage model — **two folders, machine-global by default**.
Storage is just *where fetched datasets go* and *where the produced cache goes*; both default
to machine-global, platform-derived folders, so the repository holds only the manifest and
the git-ignored `.datamanifest/` directory:

    datasets_dir  = "\$user_data_dir/datamanifest/shared/datasets"            # fetched (shared, keyed)
    datacache_dir = "\$user_cache_dir/datamanifest/projects/\$project/cached"  # produced (per-project)

There is **no scope, no prefix, no derived/app name** — the folder you set *is* the location.
A relative value is relative to the project root (`\$repo`) — `datasets_dir = "datasets"`
restores the pre-spec-v5 repo-local layout; absolute / `~` / `\$symbol`-rooted paths are used
as written.

A path may interpolate `\$`-**symbols**. Predefined:

- `\$user_data_dir`  → `platformdirs.user_data_dir()` (bare — no app name; persistent)
- `\$user_cache_dir` → `platformdirs.user_cache_dir()` (bare; reclaimable)
- `\$repo`           → the project root (manifest directory; base for relative paths)
- `\$project`        → the project name (basename of the project root; overridable as a
  bare `project` field on the ladder)

Any other bare `[_STORAGE]` key is a **user-defined symbol**, optionally host-specific via
`[_STORAGE._HOST."<glob>"]`. The same `[_STORAGE]` shape is read from two optional config
files — `.datamanifest/config.toml` (per-checkout, git-ignored) and
`\$XDG_CONFIG_HOME/datamanifest/config.toml` (user-global) — see [`config_layers`].
Resolution ladder (first match wins): `DATAMANIFEST_<NAME>` env → checkout config (`_HOST`
glob, then base) → manifest `[_STORAGE._HOST.<glob>]` → manifest `[_STORAGE]` → user config
(`_HOST` glob, then base) → built-in default. The two fields are overridable by exactly two
env vars, `DATAMANIFEST_DATASETS_DIR` / `DATAMANIFEST_DATACACHE_DIR`.

Every resolver takes `storage_config` as either a single `[_STORAGE]`-shaped dict (one
layer — the manifest) or a vector of such dicts in precedence order (the full ladder, as
built by [`config_layers`]).

The module is intentionally pure: given explicit `env` / `host` arguments it is deterministic
and testable ([`config_layers`] is the one function that reads files). Linux is the primary
verified target; macOS / Windows follow the same `platformdirs` conventions.
"""
module Storage

using TOML
using SHA

export expand_path_expr, resolve_symbol, datasets_dir, datacache_dir, dataset_storage_path,
    datasets_pools, datacache_pools, user_state_dir, user_symbols, PREDEFINED_SYMBOLS,
    RESERVED_STORAGE_KEYS, POOL_DEFAULTS, legacy_data_root,
    config_layers, local_config_path, user_config_path,
    canonical_write, lock_stale_age, DEFAULT_LOCK_STALE_AGE

"""Predefined `\$`-symbols (platform/project-resolved; never user-redefinable shadows)."""
const PREDEFINED_SYMBOLS = ("user_data_dir", "user_cache_dir", "repo", "project")

"""Reserved `[_STORAGE]` keys that are NOT user-defined symbols (the folder fields, the read-pool
list fields, the `project` name, the `canonical` write directive, and `_HOST`)."""
const RESERVED_STORAGE_KEYS = ("datasets_dir", "datacache_dir",
                               "datasets_pools", "datacache_pools", "project", "canonical",
                               "_HOST")

"""Built-in default field values (spec-v5: machine-global; relative ⇒ repo-relative)."""
const _DEFAULT_DATASETS_DIR = "\$user_data_dir/datamanifest/shared/datasets"
const _DEFAULT_DATACACHE_DIR = "\$user_cache_dir/datamanifest/projects/\$project/cached"

"""A storage configuration: one `[_STORAGE]`-shaped dict, or a vector of them in precedence
order (checkout config → manifest → user config; see [`config_layers`])."""
const ConfigLike = Union{AbstractDict,AbstractVector}

# The configuration layers of `storage_config`, in precedence order.
_layers(sc::AbstractDict) = AbstractDict[sc]
_layers(sc::AbstractVector) = AbstractDict[l for l in sc if l isa AbstractDict]

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

# --- scoped config files (spec-v5) -------------------------------------------

"""Checkout-config path relative to the project root (inside the git-ignored
`.datamanifest/` directory, beside the state file)."""
const LOCAL_CONFIG_RELPATH = joinpath(".datamanifest", "config.toml")

"""
    local_config_path(project_root) -> String

The per-checkout config file (`<project_root>/.datamanifest/config.toml`), or `""` when no
project root is known.
"""
local_config_path(project_root::AbstractString)::String =
    isempty(project_root) ? "" : joinpath(String(project_root), LOCAL_CONFIG_RELPATH)

"""
    user_config_path(env=ENV) -> String

The user-global config file: `\$XDG_CONFIG_HOME/datamanifest/config.toml` (default
`~/.config/datamanifest/config.toml`).
"""
function user_config_path(env=ENV)::String
    base = String(get(env, "XDG_CONFIG_HOME", ""))
    isempty(base) && (base = joinpath(String(get(env, "HOME", homedir())), ".config"))
    return joinpath(base, "datamanifest", "config.toml")
end

# Read a `[_STORAGE]`-shaped config file; empty dict when absent or unreadable.
function _read_config_file(path::AbstractString)::Dict{String,Any}
    (isempty(path) || !isfile(path)) && return Dict{String,Any}()
    try
        t = TOML.parsefile(String(path))
        return t isa AbstractDict ? Dict{String,Any}(t) : Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

"""
    config_layers(storage_config=Dict(); project_root="", env=ENV) -> Vector{Dict}

The full spec-v5 configuration chain, in precedence order: the checkout config
(`.datamanifest/config.toml`), the manifest's `[_STORAGE]` (`storage_config`), and the
user-global config (`\$XDG_CONFIG_HOME/datamanifest/config.toml`). Each layer is
`[_STORAGE]`-shaped (fields, pools, `project`, symbols, `_HOST` sub-tables); within a layer
a `_HOST` glob match beats the base value, and the environment (`DATAMANIFEST_<NAME>`) beats
every layer. Pass the result as `storage_config` to any resolver.
"""
function config_layers(storage_config::AbstractDict=Dict{String,Any}();
                       project_root::AbstractString="", env=ENV)::Vector{Dict{String,Any}}
    return Dict{String,Any}[
        _read_config_file(_locate_local_config(project_root)),
        Dict{String,Any}(storage_config),
        _read_config_file(user_config_path(env)),
    ]
end

# The checkout-config file to read for `project_root`: the project's own
# `.datamanifest/config.toml` when present; in a linked `git worktree` without one, the
# corresponding file in the **main checkout** (a worktree starts without the git-ignored
# `.datamanifest/` directory, so worktrees share the per-checkout scope — the same
# rationale as the spec-v5.1 state-file fallback). A config file present in the worktree
# itself always wins.
function _locate_local_config(project_root::AbstractString)::String
    path = local_config_path(project_root)
    (isempty(path) || isfile(path)) && return path
    main = _main_checkout_dir(abspath(String(project_root)))
    isempty(main) && return path
    mainpath = local_config_path(main)
    return isfile(mainpath) ? mainpath : path
end

"""
    _main_checkout_dir(dir) -> String

The directory in the **main checkout** corresponding to `dir` when `dir` lives inside a
linked `git worktree`; `""` when `dir` is the main checkout itself, is not in a git
repository, the main repository is bare, the mapped directory does not exist, or `git` is
unavailable. Resolved by asking the `git` executable (the on-disk worktree layout is git
internal), so any failure simply disables the fallback.
"""
function _main_checkout_dir(dir::AbstractString)::String
    d = abspath(String(dir))
    isdir(d) || return ""
    out = try
        read(pipeline(`git -C $d rev-parse --git-dir --git-common-dir --show-toplevel`;
                      stderr=devnull), String)
    catch e
        e isa Union{Base.IOError,Base.ProcessFailedException,SystemError} || rethrow()
        return ""
    end
    lines = split(strip(out), '\n')
    length(lines) == 3 || return ""
    # Relative outputs are relative to `d` (the `git -C` working directory).
    gitdir, commondir, toplevel =
        [normpath(isabspath(String(l)) ? String(l) : joinpath(d, String(l))) for l in lines]
    gitdir == commondir && return ""            # main checkout (not a linked worktree)
    basename(commondir) == ".git" || return ""  # bare main repository: no main checkout
    mapped = normpath(joinpath(dirname(commondir), relpath(d, toplevel)))
    return isdir(mapped) ? mapped : ""
end

# --- symbol discovery & resolution -------------------------------------------

"""
    user_symbols(storage_config) -> Vector{String}

The user-defined symbol names across the configuration layers (every bare key that is not a
reserved field / `_HOST`), including those that appear only under `_HOST` patterns. Sorted.
"""
function user_symbols(storage_config::ConfigLike)::Vector{String}
    names = Set{String}()
    for layer in _layers(storage_config)
        for (k, _) in layer
            ks = String(k)
            ks in RESERVED_STORAGE_KEYS && continue
            push!(names, ks)
        end
        hosts = get(layer, "_HOST", nothing)
        if hosts isa AbstractDict
            for (_, entry) in hosts
                entry isa AbstractDict || continue
                for (kk, _) in entry
                    String(kk) in RESERVED_STORAGE_KEYS && continue
                    push!(names, String(kk))
                end
            end
        end
    end
    return sort!(collect(names))
end

# The raw value for a symbol/field `name` from the resolution ladder (env, then per layer:
# _HOST glob → base), or `nothing` when none applies. The value is a path expression (not
# yet expanded).
function _ladder_value(name::AbstractString, storage_config::ConfigLike, env, host)
    envkey = "DATAMANIFEST_$(uppercase(name))"
    haskey(env, envkey) && !isempty(env[envkey]) && return String(env[envkey])
    for layer in _layers(storage_config)
        hosts = get(layer, "_HOST", nothing)
        if hosts isa AbstractDict
            for pat in sort(collect(keys(hosts)))  # deterministic
                entry = hosts[pat]
                if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, name)
                    return String(entry[name])
                end
            end
        end
        (haskey(layer, name) && !isempty(string(layer[name]))) &&
            return String(layer[name])
    end
    return nothing
end

# The raw, uncoerced ladder value for a scalar config field (env string first, then per
# layer: `_HOST` glob → base, whatever TOML type the layer holds); `nothing` when
# undefined. The scalar sibling of `_ladder_value`, whose String-coercing contract fits
# path expressions only (a TOML number would not survive it).
function _ladder_raw(name::AbstractString, storage_config::ConfigLike, env, host)
    envkey = "DATAMANIFEST_$(uppercase(name))"
    haskey(env, envkey) && !isempty(env[envkey]) && return String(env[envkey])
    for layer in _layers(storage_config)
        hosts = get(layer, "_HOST", nothing)
        if hosts isa AbstractDict
            for pat in sort(collect(keys(hosts)))  # deterministic
                entry = hosts[pat]
                (_glob_match(pat, host) && entry isa AbstractDict && haskey(entry, name)) &&
                    return entry[name]
            end
        end
        haskey(layer, name) && return layer[name]
    end
    return nothing
end

"""
    canonical_write(; storage_config=Dict(), env=ENV, host=gethostname()) -> Bool

The `canonical` manifest-write directive (default `false`) — opt in to piping every
persisted manifest through the Python `datamanifest format` CLI for cross-tool
byte-identical output. Resolved on the ordinary ladder: `DATAMANIFEST_CANONICAL` env →
config layers (per layer: `_HOST` glob → base). The value may be a TOML boolean or a
string; "1"/"true"/"yes"/"on" (case-insensitive) are truthy, anything else is false.
"""
function canonical_write(; storage_config::ConfigLike=Dict{String,Any}(), env=ENV,
                         host::AbstractString=gethostname())::Bool
    raw = _ladder_raw("canonical", storage_config, env, host)
    raw === nothing && return false
    raw isa Bool && return raw
    return lowercase(strip(string(raw))) in ("1", "true", "yes", "on")
end

"""Built-in lock staleness age in seconds (the `lock_stale_age` field default, spec-v5.3)."""
const DEFAULT_LOCK_STALE_AGE = 30.0

"""
    lock_stale_age(; storage_config=Dict(), env=ENV, host=gethostname()) -> Float64

The materialization-lock staleness age in seconds — the spec-v5.3 config field
`lock_stale_age` (default 30), resolved on the ordinary ladder:
`DATAMANIFEST_LOCK_STALE_AGE` env → config layers (per layer: `_HOST` glob → base). The
value may be a TOML number or a numeric string; an unparsable or non-positive value falls
back to the default. See `PipeLines.materialize` for what the staleness age governs.
"""
function lock_stale_age(; storage_config::ConfigLike=Dict{String,Any}(), env=ENV,
                        host::AbstractString=gethostname())::Float64
    raw = _ladder_raw("lock_stale_age", storage_config, env, host)
    raw === nothing && return DEFAULT_LOCK_STALE_AGE
    v = raw isa Real ? Float64(raw) : tryparse(Float64, strip(string(raw)))
    return (v === nothing || !isfinite(v) || v <= 0) ? DEFAULT_LOCK_STALE_AGE : v
end

"""
    resolve_symbol(name; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

Resolve a `\$`-symbol `name`. Ladder: `DATAMANIFEST_<NAME>` env → the configuration layers
(per layer: `_HOST.<glob>`, then base) → predefined default (`user_data_dir` /
`user_cache_dir` / `repo` / `project` — the last is the basename of the project root). A
ladder value is itself a path expression (may reference other symbols). An undefined
non-predefined symbol is an error.
"""
function resolve_symbol(name::AbstractString; project_root::AbstractString="",
                        storage_config::ConfigLike=Dict{String,Any}(), env=ENV,
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
    name == "project" &&
        return basename(normpath(abspath(isempty(project_root) ? pwd() : String(project_root))))
    error("Unknown storage symbol \$$name: not predefined " *
          "(user_data_dir/user_cache_dir/repo/project) and not defined in [_STORAGE] " *
          "or a config file.")
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
                          storage_config::ConfigLike=Dict{String,Any}(),
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
# DATAMANIFEST_<FIELD> env → the config layers (per layer: _HOST → base) → built-in default;
# then expand symbols and resolve a relative result against the project root.
function _field_dir(field::AbstractString, default::AbstractString;
                    project_root::AbstractString, storage_config::ConfigLike, env, host)::String
    raw = _ladder_value(field, storage_config, env, host)
    raw === nothing && (raw = default)
    p = expand_path_expr(raw; project_root=project_root, storage_config=storage_config,
                         env=env, host=host)
    return isabspath(p) ? p :
        (isempty(project_root) ? p : joinpath(String(project_root), p))
end

"""
    datasets_dir(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

The resolved fetched-datasets folder (default the machine-global shared store,
`\$user_data_dir/datamanifest/shared/datasets`). Overridable by `DATAMANIFEST_DATASETS_DIR`,
a config-file / `[_STORAGE]` `datasets_dir` (host-composable via `_HOST`) — e.g.
`datasets_dir = "datasets"` for the repo-local layout.
"""
datasets_dir(; project_root::AbstractString="", storage_config::ConfigLike=Dict{String,Any}(),
             env=ENV, host::AbstractString=gethostname())::String =
    _field_dir("datasets_dir", _DEFAULT_DATASETS_DIR;
               project_root=project_root, storage_config=storage_config, env=env, host=host)

"""
    datacache_dir(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> String

The resolved produced-cache folder (default the per-project
`\$user_cache_dir/datamanifest/projects/\$project/cached`). Overridable by
`DATAMANIFEST_DATACACHE_DIR`, a config-file / `[_STORAGE]` `datacache_dir` (host-composable
via `_HOST`) — e.g. `datacache_dir = "cached"` for the repo-local layout.
"""
datacache_dir(; project_root::AbstractString="", storage_config::ConfigLike=Dict{String,Any}(),
              env=ENV, host::AbstractString=gethostname())::String =
    _field_dir("datacache_dir", _DEFAULT_DATACACHE_DIR;
               project_root=project_root, storage_config=storage_config, env=env, host=host)

# ── Read pools (spec-v4.2+) ───────────────────────────────────────────────────
#
# A **read pool** is an extra read-only location probed for an already-present object before
# fetching/recomputing, so a dataset/artifact another project already has on this machine is
# reused in place (never written to; new writes still follow the directive). Configured via
# `datasets_pools` / `datacache_pools` (in the manifest's `[_STORAGE]` or a config file) — a
# LIST of path expressions, host-composable via `_HOST`, or the env var
# `DATAMANIFEST_DATASETS_POOLS` / `DATAMANIFEST_DATACACHE_POOLS` (`pathsep`-separated).
# Datasets default to well-known locations when undefined; datacache is opt-in (undefined ⇒
# none). An explicit empty list disables them.

"""Built-in fetched-dataset read pools, probed when `datasets_pools` is undefined (spec-v5):
the pre-v5 repo-local default (skipped when no project root is known), the shared store
(the `datasets_dir` default, so the store doubles as the default read pool), then the
legacy locations."""
const POOL_DEFAULTS = ("\$repo/datasets",
                       "\$user_data_dir/datamanifest/shared/datasets",
                       "\$user_data_dir/datamanifest/datasets",
                       "~/.cache/Datasets")

_pathsep() = Sys.iswindows() ? ';' : ':'

# The raw `*_pools` value (a Vector of path expressions, or `nothing` when undefined) via
# the env → config layers (per layer: `_HOST` glob → base) ladder.
function _pools_raw(field::AbstractString, storage_config::ConfigLike, env, host)
    envkey = "DATAMANIFEST_$(uppercase(field))"
    if haskey(env, envkey)
        return String[p for p in split(String(env[envkey]), _pathsep()) if !isempty(p)]
    end
    for layer in _layers(storage_config)
        hosts = get(layer, "_HOST", nothing)
        if hosts isa AbstractDict
            for pat in sort(collect(keys(hosts)))
                entry = hosts[pat]
                if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, field)
                    v = entry[field]
                    return v isa AbstractVector ? String[String(x) for x in v] : String[String(v)]
                end
            end
        end
        if haskey(layer, field)
            v = layer[field]
            return v isa AbstractVector ? String[String(x) for x in v] : String[String(v)]
        end
    end
    return nothing
end

function _resolve_pools(field::AbstractString, defaults; project_root, storage_config, env, host)
    raw = _pools_raw(field, storage_config, env, host)
    # The built-in `$repo/datasets` default needs a project root; skip it when none is known.
    exprs = raw === nothing ?
        String[e for e in defaults if !(isempty(project_root) && occursin("\$repo", e))] : raw
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
already-present `<pool>/<key>` before downloading. `datasets_pools` (in `[_STORAGE]` or a
config file; host-composable via `_HOST`, or `DATAMANIFEST_DATASETS_POOLS`) gives them; when
**undefined** the built-in [`POOL_DEFAULTS`] apply; an explicit empty list disables them.
Each entry is a path expression.
"""
datasets_pools(; project_root::AbstractString="", storage_config::ConfigLike=Dict{String,Any}(),
               env=ENV, host::AbstractString=gethostname())::Vector{String} =
    _resolve_pools("datasets_pools", POOL_DEFAULTS; project_root=project_root,
                   storage_config=storage_config, env=env, host=host)

"""
    datacache_pools(; project_root="", storage_config=Dict(), env=ENV, host=gethostname()) -> Vector{String}

Resolved absolute **produced-artifact read pools** — extra read-only locations probed for an
already-produced `<pool>/<cachetype>[/<version>]/<hash>` before recomputing.
`datacache_pools` (in `[_STORAGE]` or a config file; host-composable via `_HOST`, or
`DATAMANIFEST_DATACACHE_POOLS`); **opt-in** — undefined means *no* pools (produced artifacts
carry no content checksum, only their identity + `config.toml` validation). An empty list is
likewise none.
"""
datacache_pools(; project_root::AbstractString="", storage_config::ConfigLike=Dict{String,Any}(),
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
                              storage_config::ConfigLike=Dict{String,Any}(),
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

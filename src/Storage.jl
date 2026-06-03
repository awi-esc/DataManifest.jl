"""
    Storage

Pure resolver for the spec-v2 `\$`-folder-variable storage model.

A **folder** is a named location referenced as a `\$`-variable. There is one
namespace with three built-in members and any number of user-defined ones:

- `\$data`  → `platformdirs.user_data_dir("datamanifest")` + `/Datasets`
- `\$cache` → `platformdirs.user_cache_dir("datamanifest")` + `/Datasets`
- `\$repo`  → `<project_root>/datasets`
- user-defined: any other key under `[_STORAGE]` (e.g. `scratch = "…"` → `\$scratch`)

Default root locations are **language-independent** — they match Python's
`platformdirs` so a peer tool resolves the same dataset to the same on-disk path
(NOT the Julia depot). The core knows *locations only* — no lifetime policy.

Two kinds of value:

- **Selectors** (`store`, `[_STORAGE].default`) — a `\$`-folder reference,
  optionally with a literal sub-path: `\$cache/derived`. Resolved by
  [`selector_root`]; the dataset lands at `<root>[/subpath]/<key>`.
- **Path expressions** (`[_STORAGE]` values, `local_path`) — full paths that may
  interpolate `\$`-folder variables, `\$USER`/env vars, and `~`. Resolved by
  [`expand_path_expr`].

Every folder variable — built-in and user-defined alike — resolves through one
ladder (see [`folder_root`]). The module is intentionally pure: given explicit
`env` / `host` / `profile` arguments it is deterministic and testable without
touching the real environment.

Linux is the primary verified target; macOS / Windows defaults follow the same
`platformdirs` conventions (documented inline, less heavily exercised).
"""
module Storage

export folder_root, selector_root, expand_path_expr, legacy_data_root, BUILTIN_FOLDERS

"""Built-in folder variables (the only ones with a built-in default location)."""
const BUILTIN_FOLDERS = ("data", "cache", "repo")

"""Reserved `[_STORAGE]` keys that are NOT folder variables."""
const RESERVED_STORAGE_KEYS = ("default", "_HOST", "_PROFILE")

# --- glob matching (`*`, `?`) for `_HOST` patterns ---------------------------

const _GLOB_SPECIAL = Set(['.', '\\', '+', '-', '^', '$', '|', '(', ')', '[', ']', '{', '}'])

"""
    _glob_match(pattern, s) -> Bool

Match `s` against a shell-style glob `pattern` where `*` matches any run of
characters and `?` matches a single character. The whole string must match.
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

# --- platformdirs-equivalent default roots -----------------------------------

"""
    _user_data_dir(env) -> String

`platformdirs.user_data_dir("datamanifest")`. Linux:
`\$XDG_DATA_HOME` (default `~/.local/share`) + `/datamanifest`. macOS:
`~/Library/Application Support/datamanifest`. Windows: `%LOCALAPPDATA%` +
`/datamanifest/datamanifest` (platformdirs doubles the missing appauthor).
"""
function _user_data_dir(env)::String
    if Sys.iswindows()
        base = get(env, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
        return joinpath(base, "datamanifest", "datamanifest")
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Application Support", "datamanifest")
    else
        base = get(env, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
        return joinpath(base, "datamanifest")
    end
end

"""
    _user_cache_dir(env) -> String

`platformdirs.user_cache_dir("datamanifest")`. Linux: `\$XDG_CACHE_HOME`
(default `~/.cache`) + `/datamanifest`. macOS: `~/Library/Caches/datamanifest`.
Windows: `%LOCALAPPDATA%` + `/datamanifest/datamanifest/Cache`.
"""
function _user_cache_dir(env)::String
    if Sys.iswindows()
        base = get(env, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))
        return joinpath(base, "datamanifest", "datamanifest", "Cache")
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Caches", "datamanifest")
    else
        base = get(env, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
        return joinpath(base, "datamanifest")
    end
end

"""
    _builtin_default(name, project_root, env) -> Union{String,Nothing}

The language-independent built-in default root for a built-in folder, or
`nothing` for a user-defined folder (which has no built-in default).
"""
function _builtin_default(name::AbstractString, project_root::AbstractString, env)
    if name == "repo"
        return joinpath(String(project_root), "datasets")
    elseif name == "cache"
        return joinpath(_user_cache_dir(env), "Datasets")
    elseif name == "data"
        return joinpath(_user_data_dir(env), "Datasets")
    else
        return nothing
    end
end

"""
    legacy_data_root(env=ENV) -> String

The pre-v1.1 default datasets folder — `\$XDG_CACHE_HOME/Datasets` (default
`~/.cache/Datasets`). A **read-only** back-compat probe location: spec-v1.1 moved
the default `data` folder under a `datamanifest/` namespace (see `_user_data_dir`),
orphaning datasets downloaded by older versions here. Read resolution probes it
last so old downloads still resolve; new writes never land here. Must match the
Python tool's `storage.legacy_data_root()`.
"""
function legacy_data_root(env=ENV)::String
    base = get(env, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
    return joinpath(base, "Datasets")
end

# --- folder-variable name discovery ------------------------------------------

# The set of names that are folder *variables* (so `$NAME` in a path expression
# expands to a folder root rather than an env var): built-ins plus every name
# defined anywhere in `[_STORAGE]` (base keys and `_HOST` / `_PROFILE` overrides),
# excluding the reserved keys.
function _folder_var_names(storage_config::AbstractDict)::Set{String}
    names = Set{String}(BUILTIN_FOLDERS)
    for (k, _) in storage_config
        ks = String(k)
        ks in RESERVED_STORAGE_KEYS && continue
        push!(names, ks)
    end
    for sub in ("_HOST", "_PROFILE")
        t = get(storage_config, sub, nothing)
        if t isa AbstractDict
            for (_, entry) in t
                if entry isa AbstractDict
                    for (kk, _) in entry
                        push!(names, String(kk))
                    end
                end
            end
        end
    end
    return names
end

# --- path-expression expansion -----------------------------------------------

"""
    expand_path_expr(expr; project_root="", storage_config=Dict(), env=ENV,
                     host=gethostname(), profile=…) -> String

Expand a **path expression**: `\$NAME` / `\${NAME}` and a leading `~`. `\$NAME`
expands to the folder variable `NAME` (resolved through [`folder_root`]) if one is
defined, otherwise to the environment variable `NAME`; an undefined name is left
verbatim. `~` expands to the home directory.
"""
function expand_path_expr(expr::AbstractString;
                          project_root::AbstractString="",
                          storage_config::AbstractDict=Dict{String,Any}(),
                          env=ENV,
                          host::AbstractString=gethostname(),
                          profile::AbstractString=get(ENV, "DATAMANIFEST_PROFILE", ""),
                          _seen::Set{String}=Set{String}())::String
    s = String(expr)
    fvars = _folder_var_names(storage_config)

    resolve(name::AbstractString, whole::AbstractString) = begin
        nm = String(name)
        if nm in fvars
            return folder_root(nm; project_root=project_root, storage_config=storage_config,
                               env=env, host=host, profile=profile, _seen=_seen)
        elseif haskey(env, nm)
            return String(env[nm])
        else
            return String(whole)  # undefined: leave verbatim
        end
    end

    s = replace(s, r"\$\{[A-Za-z_][A-Za-z0-9_]*\}" => m -> resolve(m[3:end-1], m))
    s = replace(s, r"\$[A-Za-z_][A-Za-z0-9_]*" => m -> resolve(m[2:end], m))
    return expanduser(s)
end

# --- folder resolution (the unified ladder) ----------------------------------

"""
    folder_root(name; project_root="", storage_config=Dict(), env=ENV,
                host=gethostname(), profile=…) -> String

Resolve a single folder variable `name` (built-in or user-defined) to a root
directory. One ladder for every variable; the first rung that applies wins:

1. the `DATAMANIFEST_<NAME>_DIR` environment variable;
2. the `[_STORAGE._PROFILE.<profile>].<name>` entry, when `profile != ""`;
3. the first matching `[_STORAGE._HOST.<glob>].<name>` entry (glob `*`/`?` vs `host`);
4. the base `[_STORAGE].<name>` definition;
5. the built-in default (`data` / `cache` / `repo` only).

A user-defined name unresolved on every rung is an error. The value at rungs 1–4
is a **path expression** (it may interpolate other folder variables, `\$USER`/env,
`~`); a relative `repo` value is resolved against `project_root`. A folder variable
that references itself (directly or transitively) is an error.
"""
function folder_root(name::AbstractString;
                     project_root::AbstractString="",
                     storage_config::AbstractDict=Dict{String,Any}(),
                     env=ENV,
                     host::AbstractString=gethostname(),
                     profile::AbstractString=get(ENV, "DATAMANIFEST_PROFILE", ""),
                     _seen::Set{String}=Set{String}())::String
    name = String(name)
    if name in _seen
        error("Storage folder variable \$$name references itself (cycle) in [_STORAGE].")
    end
    seen2 = union(_seen, Set([name]))

    expand(raw) = expand_path_expr(string(raw); project_root=project_root,
                                   storage_config=storage_config, env=env, host=host,
                                   profile=profile, _seen=seen2)
    finalize(p) = (name == "repo" && !isabspath(p)) ? joinpath(String(project_root), p) : p

    # (1) DATAMANIFEST_<NAME>_DIR
    envkey = "DATAMANIFEST_$(uppercase(name))_DIR"
    if haskey(env, envkey) && !isempty(env[envkey])
        return finalize(expand(env[envkey]))
    end

    # (2) _PROFILE.<profile>.<name>
    if !isempty(profile)
        prof = get(storage_config, "_PROFILE", nothing)
        if prof isa AbstractDict && haskey(prof, profile)
            entry = prof[profile]
            if entry isa AbstractDict && haskey(entry, name)
                return finalize(expand(entry[name]))
            end
        end
    end

    # (3) first matching _HOST.<glob>.<name>
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for pat in sort(collect(keys(hosts)))  # deterministic iteration
            entry = hosts[pat]
            if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, name)
                return finalize(expand(entry[name]))
            end
        end
    end

    # (4) base [_STORAGE].<name>
    if !(name in RESERVED_STORAGE_KEYS) && haskey(storage_config, name) &&
       !isempty(string(storage_config[name]))
        return finalize(expand(storage_config[name]))
    end

    # (5) built-in default (data/cache/repo only)
    d = _builtin_default(name, project_root, env)
    d !== nothing && return d
    error("Unknown storage folder variable \$$name: not built-in (data/cache/repo) " *
          "and not defined in [_STORAGE].")
end

# --- selector resolution -----------------------------------------------------

"""
    selector_root(selector; project_root="", storage_config=Dict(), env=ENV,
                  host=gethostname(), profile=…) -> String

Resolve a `store` / `default` **selector** to a root directory. A selector is a
`\$`-folder reference optionally followed by a literal sub-path:
`\$<folder>[/<subpath>]` → `<resolved-folder>[/<subpath>]`. The dataset's bytes
land at `<root>/<key>`. A non-`\$` (bare) selector is rejected — spec-v2 selectors
MUST be `\$`-references (bare names are migrated by the caller before this point).
"""
function selector_root(selector::AbstractString; kwargs...)::String
    s = String(selector)
    if !startswith(s, "\$")
        error("Invalid storage selector \"$s\": expected a \$-folder reference " *
              "(e.g. \"\$data\" or \"\$cache/sub\").")
    end
    body = s[2:end]
    parts = split(body, '/'; limit=2)
    name = String(parts[1])
    root = folder_root(name; kwargs...)
    if length(parts) == 2 && !isempty(parts[2])
        return joinpath(root, String(parts[2]))
    end
    return root
end

# --- safe-materialization path helpers ---------------------------------------

export tmp_path, lock_path, marker_path, is_complete

"""
    tmp_path(target) -> String

Sibling staging path (`<target>.tmp`) a fetcher populates before the atomic
publish. Always a sibling of `target`, so it never pollutes a directory dataset.
"""
tmp_path(target::AbstractString)::String = string(target, ".tmp")

"""
    lock_path(target) -> String

Sibling pidfile-lock path (`<target>.lock`) held while a dataset is being
materialized.
"""
lock_path(target::AbstractString)::String = string(target, ".lock")

"""
    marker_path(target) -> String

Completion-marker path for `target`: `<target>/.complete` when `target` is a
directory, `<target>.complete` (a sibling) otherwise. A present marker means the
entry was fully materialized; its absence means the entry MUST be treated as
absent (re-fetch), even when `target` itself exists (a partial fetch).
"""
marker_path(target::AbstractString)::String =
    isdir(target) ? joinpath(String(target), ".complete") : string(target, ".complete")

"""
    is_complete(target) -> Bool

`true` iff `target`'s completion marker exists. Readers MUST treat a missing
marker as absent even when `target` itself is present.
"""
is_complete(target::AbstractString)::Bool = isfile(marker_path(target))

end # module Storage

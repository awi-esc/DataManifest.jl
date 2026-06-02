"""
    Storage

Pure resolver from a store name (`data` | `cache` | `repo` | `mount`) to a root
directory, matching the spec-v1.1 storage model.

Default root locations are **language-independent** — they match Python's
`platformdirs` so a peer tool resolves the same dataset to the same on-disk path
(NOT the Julia depot):

- `data`  → `platformdirs.user_data_dir("datamanifest")` + `/Datasets`
- `cache` → `platformdirs.user_cache_dir("datamanifest")` + `/Datasets`
- `repo`  → `<project_root>/datasets`

Linux is the primary verified target; macOS / Windows defaults follow the same
`platformdirs` conventions (documented inline, less heavily exercised).

The module is intentionally pure: given explicit `env` / `host` / `profile`
arguments it is deterministic and testable without touching the real
environment.
"""
module Storage

export store_root

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

# --- path expansion ----------------------------------------------------------

"""
    _expand(path, env) -> String

Expand `\$VAR` / `\${VAR}` (against `env`) and a leading `~` in `path`. An
undefined variable is left verbatim.
"""
function _expand(path::AbstractString, env)::String
    s = String(path)
    s = replace(s, r"\$\{[A-Za-z_][A-Za-z0-9_]*\}" => m -> get(env, String(m[3:end-1]), m))
    s = replace(s, r"\$[A-Za-z_][A-Za-z0-9_]*" => m -> get(env, String(m[2:end]), m))
    return expanduser(s)
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
    _default_root(store, project_root, env) -> String

The language-independent default root for `store` when nothing overrides it.
"""
function _default_root(store::AbstractString, project_root::AbstractString, env)::String
    if store == "repo"
        return joinpath(String(project_root), "datasets")
    elseif store == "cache"
        return joinpath(_user_cache_dir(env), "Datasets")
    else  # "data", "mount" (no v1.1 default specified), and any unknown store
        return joinpath(_user_data_dir(env), "Datasets")
    end
end

# Finalize a configured/explicit value: expand vars/`~`, and resolve a relative
# `repo` value against the project root.
function _finalize(raw, store::AbstractString, project_root::AbstractString, env)::String
    p = _expand(string(raw), env)
    if store == "repo" && !isabspath(p)
        p = joinpath(String(project_root), p)
    end
    return p
end

# --- public resolver ---------------------------------------------------------

"""
    store_root(store; project_root="", storage_config=Dict(), env=ENV,
               host=gethostname(), profile=get(ENV, "DATAMANIFEST_PROFILE", "")) -> String

Resolve `store` to a root directory. Per-store precedence (first that applies):

1. the `DATAMANIFEST_<STORE>_DIR` environment variable;
2. the `_PROFILE.<profile>` entry, when `profile != ""`;
3. the first matching `_HOST.<glob>` entry (glob `*`/`?` against `host`);
4. the base `[_STORAGE].<store>` entry;
5. the language-independent default.

`~` and `\$VAR` are expanded; a relative `repo` value is resolved against
`project_root`. `storage_config` is the parsed `[_STORAGE]` table (with optional
`_HOST` / `_PROFILE` sub-tables).
"""
function store_root(store::AbstractString;
                    project_root::AbstractString="",
                    storage_config::AbstractDict=Dict{String,Any}(),
                    env=ENV,
                    host::AbstractString=gethostname(),
                    profile::AbstractString=get(ENV, "DATAMANIFEST_PROFILE", ""))::String
    store = isempty(store) ? "data" : String(store)

    # (1) DATAMANIFEST_<STORE>_DIR
    envkey = "DATAMANIFEST_$(uppercase(store))_DIR"
    if haskey(env, envkey) && !isempty(env[envkey])
        return _finalize(env[envkey], store, project_root, env)
    end

    # (2) _PROFILE.<profile>
    if !isempty(profile)
        prof = get(storage_config, "_PROFILE", nothing)
        if prof isa AbstractDict && haskey(prof, profile)
            entry = prof[profile]
            if entry isa AbstractDict && haskey(entry, store)
                return _finalize(entry[store], store, project_root, env)
            end
        end
    end

    # (3) first matching _HOST.<glob>
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for pat in sort(collect(keys(hosts)))  # deterministic iteration
            entry = hosts[pat]
            if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, store)
                return _finalize(entry[store], store, project_root, env)
            end
        end
    end

    # (4) base [_STORAGE].<store>
    if haskey(storage_config, store) && !isempty(string(storage_config[store]))
        return _finalize(storage_config[store], store, project_root, env)
    end

    # (5) language-independent default
    return _default_root(store, project_root, env)
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

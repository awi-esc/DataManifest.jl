"""
    Storage

Pure resolver for the spec-v3 storage model: **bare folder roots** + **layer-applied
content prefixes** (`datasets/` for fetch, `cached/` for produce) + an optional **scope**
partition segment.

A **folder** is a named top-level *location* referenced as a `\$`-variable. One namespace,
three built-in members plus any number of user-defined ones:

- `\$data`  → `\$DATAMANIFEST_DIR` if set, else `platformdirs.user_data_dir("datamanifest")`
- `\$cache` → `\$DATAMANIFEST_DIR` if set, else `platformdirs.user_cache_dir("datamanifest")`
- `\$repo`  → `<project_root>`
- user-defined: any other bare key under `[_STORAGE]` (`scratch = "…"` → `\$scratch`)

A folder resolves to a **bare root** (no trailing `Datasets`/`datasets`). The consuming
layer composes the rest of the path:

    fetched:  <root>[/subpath]/<datasets-prefix>/[<datasets-scope>/]<key>
    produced: <root>[/subpath]/<cached-prefix>/[<cached-scope>/]<cachetype>/[<version>/]<hash>

So the same folder holds fetched data and produced artifacts as sibling subtrees. Default
roots are language-independent (Python's `platformdirs` is the normative reference); the
core knows *locations only* — no lifetime policy.

Two kinds of value:

- **Selectors** (`store`, `[_STORAGE].default`) — a `\$`-folder reference, optionally with a
  sub-path (`\$cache/sub`). Resolved by [`selector_root`] to `<root>[/subpath]`; the layer
  then appends prefix/scope/key (see [`store_dir`]).
- **Path expressions** (`[_STORAGE]` values, `local_path`) — full paths interpolating
  `\$`-folder variables, `\$USER`/env, and `~`. Resolved by [`expand_path_expr`].

Every folder variable resolves through one ladder (see [`folder_root`]):
`DATAMANIFEST_<NAME>_DIR` env → `[_STORAGE._HOST.<glob>].<name>` → `[_STORAGE].<name>` →
built-in default. (`_PROFILE` is shelved in spec-v3 — reserved/preserved, not resolved.)

The module is intentionally pure: given explicit `env` / `host` arguments it is
deterministic and testable without touching the real environment. Linux is the primary
verified target; macOS / Windows defaults follow the same `platformdirs` conventions.
"""
module Storage

using TOML
using SHA

export folder_root, selector_root, store_dir, expand_path_expr,
    content_prefix, content_scope, project_id,
    legacy_data_root, legacy_v2_roots, BUILTIN_FOLDERS

"""Built-in folder variables (the only ones with a built-in default location)."""
const BUILTIN_FOLDERS = ("data", "cache", "repo")

"""Reserved `[_STORAGE]` keys that are NOT folder variables (spec-v3)."""
const RESERVED_STORAGE_KEYS = ("default", "_HOST", "_PREFIX", "_SCOPE", "_PROFILE")

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

# --- platformdirs-equivalent default roots (bare app dirs, spec-v3) ----------

"""
    _user_data_dir(env) -> String

`platformdirs.user_data_dir("datamanifest")` — the **bare** app data dir (no trailing
`datasets`). Linux: `\$XDG_DATA_HOME` (default `~/.local/share`) + `/datamanifest`. macOS:
`~/Library/Application Support/datamanifest`. Windows: `%LOCALAPPDATA%` +
`/datamanifest/datamanifest`.
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

`platformdirs.user_cache_dir("datamanifest")` — the **bare** app cache dir. Linux:
`\$XDG_CACHE_HOME` (default `~/.cache`) + `/datamanifest`. macOS:
`~/Library/Caches/datamanifest`. Windows: `%LOCALAPPDATA%` + `/datamanifest/datamanifest/Cache`.
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

The language-independent built-in **bare root** for a built-in folder, or `nothing` for a
user-defined folder. `DATAMANIFEST_DIR`, when set, is the application base for `\$data` and
`\$cache`; `\$repo` is always project-relative.
"""
function _builtin_default(name::AbstractString, project_root::AbstractString, env)
    if name == "repo"
        return String(project_root)
    elseif name == "data" || name == "cache"
        dir = get(env, "DATAMANIFEST_DIR", "")
        !isempty(dir) && return String(dir)
        return name == "cache" ? _user_cache_dir(env) : _user_data_dir(env)
    else
        return nothing
    end
end

"""
    legacy_data_root(env=ENV) -> String

The pre-v1.1 default datasets folder — `\$XDG_CACHE_HOME/Datasets` (default
`~/.cache/Datasets`). A **read-only** back-compat probe location, checked last so old
downloads still resolve; new writes never land here.
"""
function legacy_data_root(env=ENV)::String
    base = get(env, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
    return joinpath(base, "Datasets")
end

"""
    legacy_v2_roots(env=ENV) -> Vector{String}

The spec-v2 (v0.17.0) dataset roots — the bare app dirs plus a capital-`Datasets` segment
(`<user_data_dir>/Datasets`, `<user_cache_dir>/Datasets`). spec-v3 lowercased the prefix to
`datasets/` and moved folders to bare roots, orphaning anything v0.17.0 wrote. These are
**read-only** transitional probe roots (a dataset's `<root>/<key>` is checked under each);
new writes never land here.
"""
function legacy_v2_roots(env=ENV)::Vector{String}
    return [joinpath(_user_data_dir(env), "Datasets"),
            joinpath(_user_cache_dir(env), "Datasets")]
end

# --- folder-variable name discovery ------------------------------------------

# Names that are folder *variables* (so `$NAME` in a path expression expands to a folder
# root rather than an env var): built-ins plus every base/_HOST-defined name, excluding the
# reserved keys. `_PREFIX` / `_SCOPE` inner keys (`datasets`/`cached`) are NOT folder vars.
function _folder_var_names(storage_config::AbstractDict)::Set{String}
    names = Set{String}(BUILTIN_FOLDERS)
    for (k, _) in storage_config
        ks = String(k)
        ks in RESERVED_STORAGE_KEYS && continue
        push!(names, ks)
    end
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for (_, entry) in hosts
            if entry isa AbstractDict
                for (kk, _) in entry
                    push!(names, String(kk))
                end
            end
        end
    end
    return names
end

# --- path-expression expansion -----------------------------------------------

"""
    expand_path_expr(expr; project_root="", storage_config=Dict(), env=ENV,
                     host=gethostname()) -> String

Expand a **path expression**: `\$NAME` / `\${NAME}` and a leading `~`. `\$NAME` expands to
the folder variable `NAME` (via [`folder_root`]) if defined, otherwise the environment
variable `NAME`; an undefined name is left verbatim. `~` expands to the home directory.
"""
function expand_path_expr(expr::AbstractString;
                          project_root::AbstractString="",
                          storage_config::AbstractDict=Dict{String,Any}(),
                          env=ENV,
                          host::AbstractString=gethostname(),
                          _seen::Set{String}=Set{String}())::String
    s = String(expr)
    fvars = _folder_var_names(storage_config)

    resolve(name::AbstractString, whole::AbstractString) = begin
        nm = String(name)
        if nm in fvars
            return folder_root(nm; project_root=project_root, storage_config=storage_config,
                               env=env, host=host, _seen=_seen)
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

# --- folder resolution (the unified ladder, spec-v3) -------------------------

"""
    folder_root(name; project_root="", storage_config=Dict(), env=ENV,
                host=gethostname()) -> String

Resolve a single folder variable `name` (built-in or user-defined) to a **bare root**. One
ladder for every variable; the first rung that applies wins:

1. the `DATAMANIFEST_<NAME>_DIR` environment variable;
2. the first matching `[_STORAGE._HOST.<glob>].<name>` entry (glob `*`/`?` vs `host`);
3. the base `[_STORAGE].<name>` definition;
4. the built-in default (`\$data`/`\$cache` → `\$DATAMANIFEST_DIR` or platformdirs;
   `\$repo` → `<project_root>`).

(spec-v3 dropped the `_PROFILE` rung — `_PROFILE` is reserved/preserved, not resolved.) A
user-defined name unresolved on every rung is an error. The value at rungs 1–3 is a **path
expression**; a relative `repo` value is resolved against `project_root`. A folder variable
that references itself is an error.
"""
function folder_root(name::AbstractString;
                     project_root::AbstractString="",
                     storage_config::AbstractDict=Dict{String,Any}(),
                     env=ENV,
                     host::AbstractString=gethostname(),
                     _seen::Set{String}=Set{String}())::String
    name = String(name)
    if name in _seen
        error("Storage folder variable \$$name references itself (cycle) in [_STORAGE].")
    end
    seen2 = union(_seen, Set([name]))

    expand(raw) = expand_path_expr(string(raw); project_root=project_root,
                                   storage_config=storage_config, env=env, host=host,
                                   _seen=seen2)
    finalize(p) = (name == "repo" && !isabspath(p) && !isempty(project_root)) ?
        joinpath(String(project_root), p) : p

    # (1) DATAMANIFEST_<NAME>_DIR
    envkey = "DATAMANIFEST_$(uppercase(name))_DIR"
    if haskey(env, envkey) && !isempty(env[envkey])
        return finalize(expand(env[envkey]))
    end

    # (2) first matching _HOST.<glob>.<name>
    hosts = get(storage_config, "_HOST", nothing)
    if hosts isa AbstractDict
        for pat in sort(collect(keys(hosts)))  # deterministic iteration
            entry = hosts[pat]
            if _glob_match(pat, host) && entry isa AbstractDict && haskey(entry, name)
                return finalize(expand(entry[name]))
            end
        end
    end

    # (3) base [_STORAGE].<name>
    if !(name in RESERVED_STORAGE_KEYS) && haskey(storage_config, name) &&
       !isempty(string(storage_config[name]))
        return finalize(expand(storage_config[name]))
    end

    # (4) built-in default
    d = _builtin_default(name, project_root, env)
    d !== nothing && return d
    error("Unknown storage folder variable \$$name: not built-in (data/cache/repo) " *
          "and not defined in [_STORAGE].")
end

# --- selector resolution -----------------------------------------------------

"""
    selector_root(selector; project_root="", storage_config=Dict(), env=ENV,
                  host=gethostname()) -> String

Resolve a `store` / `default` **selector** to `<root>[/subpath]`. A selector is a
`\$`-folder reference optionally followed by a literal sub-path (`\$cache/sub`). The
consuming layer appends the content prefix, scope, and key on top (see [`store_dir`]). A
non-`\$` (bare) selector is rejected.
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

# --- content prefixes and scopes (spec-v3) -----------------------------------

"""
    content_prefix(kind; storage_config=Dict(), env=ENV) -> String

The per-layer subfolder under a folder root: resolves `DATAMANIFEST_PREFIX_<KIND>` →
`[_STORAGE._PREFIX].<kind>` → built-in default (`"datasets"` for `:datasets`, `"cached"`
for `:cached`). `kind` is `:datasets` or `:cached`.
"""
function content_prefix(kind; storage_config::AbstractDict=Dict{String,Any}(), env=ENV)::String
    k = String(kind)
    envkey = "DATAMANIFEST_PREFIX_$(uppercase(k))"
    haskey(env, envkey) && return String(env[envkey])
    p = get(storage_config, "_PREFIX", nothing)
    if p isa AbstractDict && haskey(p, k)
        return String(p[k])
    end
    return k == "cached" ? "cached" : "datasets"
end

"""
    content_scope(kind; storage_config=Dict(), env=ENV, project_root="",
                  declared_project="") -> String

The optional partition segment controlling sharing: resolves `DATAMANIFEST_SCOPE_<KIND>` →
`[_STORAGE._SCOPE].<kind>` → built-in default (**empty** for `:datasets` — shared across
projects; the **project id** for `:cached` — project-isolated). An empty string means no
scope segment.
"""
function content_scope(kind; storage_config::AbstractDict=Dict{String,Any}(), env=ENV,
                       project_root::AbstractString="", declared_project::AbstractString="")::String
    k = String(kind)
    envkey = "DATAMANIFEST_SCOPE_$(uppercase(k))"
    haskey(env, envkey) && return String(env[envkey])
    s = get(storage_config, "_SCOPE", nothing)
    if s isa AbstractDict && haskey(s, k)
        return String(s[k])
    end
    return k == "cached" ? project_id(project_root; declared=declared_project) : ""
end

# Reduce an arbitrary id to a single path-safe segment.
_sanitize_segment(s::AbstractString) = replace(String(s), r"[^A-Za-z0-9._-]" => "-")

"""
    project_id(project_root=""; declared="") -> String

The project id used as the default `cached` scope. First non-empty wins: an explicitly
`declared` id → the package identity at `project_root` (Julia `uuid` else `name` in
`Project.toml`) → a hash of the project root's absolute path (machine-local). Rendered to a
single path-safe segment.
"""
function project_id(project_root::AbstractString=""; declared::AbstractString="")::String
    !isempty(declared) && return _sanitize_segment(declared)
    pr = isempty(project_root) ? pwd() : String(project_root)
    ptoml = joinpath(pr, "Project.toml")
    if isfile(ptoml)
        try
            t = TOML.parsefile(ptoml)
            id = get(t, "uuid", get(t, "name", ""))
            !isempty(string(id)) && return _sanitize_segment(string(id))
        catch
        end
    end
    return "p-" * bytes2hex(sha256(abspath(pr)))[1:16]
end

"""
    store_dir(selector, kind; project_root="", storage_config=Dict(), env=ENV,
              host=gethostname(), declared_project="") -> String

Compose the directory **under which a key/cachetype lives** for a given selector and layer
`kind` (`:datasets` or `:cached`): `selector_root` + content prefix + (non-empty) scope. The
caller appends the `<key>` (fetch) or `<cachetype>/[<version>/]<hash>` (produce) below it.
"""
function store_dir(selector::AbstractString, kind;
                   project_root::AbstractString="",
                   storage_config::AbstractDict=Dict{String,Any}(),
                   env=ENV,
                   host::AbstractString=gethostname(),
                   declared_project::AbstractString="")::String
    root = selector_root(selector; project_root=project_root, storage_config=storage_config,
                         env=env, host=host)
    prefix = content_prefix(kind; storage_config=storage_config, env=env)
    scope = content_scope(kind; storage_config=storage_config, env=env,
                          project_root=project_root, declared_project=declared_project)
    p = root
    !isempty(prefix) && (p = joinpath(p, prefix))
    !isempty(scope) && (p = joinpath(p, scope))
    return p
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

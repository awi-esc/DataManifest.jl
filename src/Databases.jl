# Databases: types, path/URI, registry. Single module to limit linkage.
module Databases

using TOML
using URIs
using ..Config: info, warn, sha256_path, hash_path, hashable_algo, get_extract_path, get_default_toml, DEFAULT_DATASETS_FOLDER_PATH,
    COMPRESSED_FORMATS, HIDE_STRUCT_FIELDS, project_root_from_paths
using ..Storage: expand_path_expr, dataset_storage_path, datasets_dir, datacache_dir,
    datasets_pools, legacy_data_root, is_complete, config_layers, ConfigLike,
    ConfigSnapshot, canonical_write, _main_checkout_dir

# ----- Types (DatasetEntry, Database) -----
Base.@kwdef mutable struct DatasetEntry
    uri::String = ""
    uris::Vector{String} = String[]
    host::String = ""
    path::String = ""
    scheme::String = ""
    version::String = ""
    branch::String = ""
    doi::String = ""
    aliases::Vector{String} = Vector{String}()
    description::String = ""
    key::String = ""
    # Per-dataset path (spec-v4): a path expression for where this dataset lives, defaulting
    # to `$datasets_dir/$key`. Containing `$key` ⇒ a tool-managed keyed location; an exact
    # path without `$key` ⇒ a user-managed location used verbatim (maintenance never touches
    # it). Subsumes the former `store` selector and `local_path`. Empty ⇒ the keyed default.
    storage_path::String = ""
    # Expected content digest as `<algo>:<hex>` (e.g. `sha256:…`, `md5:…`); a bare
    # hex value is read as sha256 (see `init_dataset_entry`). Used for fetch-time
    # verification and change detection in the algorithm it names; empty ⇒ computed
    # (as `sha256:`) on first download. Supersedes the legacy `sha256` key (still
    # read, normalized on read; emitted as `checksum` on write). The `sha256`
    # property (getproperty/setproperty! below) preserves `entry.sha256` access.
    # Excluded from `==` (identity), as `sha256` was.
    checksum::String = ""
    skip_checksum::Bool = false
    skip_download::Bool = false
    # spec-v4.3 access mode: open the `uri` in place via a loader (typically a remote object
    # store) instead of materializing a local copy — no download, no checksum, no state-file
    # record. Requires a loader (a bare `lazy_access` with no loader is an error). Distinct
    # from `skip_download` (a management mode); the two are independent and do not combine.
    lazy_access::Bool = false
    extract::Bool = false
    format::String = ""
    shell::String = ""
    julia::String = ""
    julia_modules::Vector{String} = String[]
    loader::String = ""
    requires::Vector{String} = String[]
    # Own v1 Julia bindings parsed from `[<ds>._LANG.julia]`: `module:function`
    # refs. Empty ⇒ none declared. The write side (later item) regenerates the
    # `[<ds>._LANG.julia]` block from these; they are not emitted as flat keys.
    lang_julia_fetcher::String = ""
    lang_julia_loader::String = ""
    # Parameterized-binding payloads for the own Julia fetcher/loader: ordered
    # positional `args` and a `kwargs` map, parsed from the `{ ref, args, kwargs }`
    # table form of `[<ds>._LANG.julia].fetcher`/`loader`. Empty ⇒ the binding is a
    # bare `module:function` ref (conventional call). Values may be arbitrary TOML
    # (strings, numbers, nested arrays/tables); `$var` substitution happens later
    # at execution time, not here.
    lang_julia_fetcher_args::Vector{Any} = Any[]
    lang_julia_fetcher_kwargs::Dict{String,Any} = Dict{String,Any}()
    lang_julia_loader_args::Vector{Any} = Any[]
    lang_julia_loader_kwargs::Dict{String,Any} = Dict{String,Any}()
    # Unknown per-dataset keys (scalars and foreign `_*` sub-tables such as
    # `[<ds>._LANG.<other>]`) are kept here verbatim for lossless round-trip.
    # The own `[<ds>._LANG.julia]` subtable is consumed into the fields above
    # and removed from here; every foreign `_LANG.<other>` stays verbatim.
    extra::Dict{String,Any} = Dict{String,Any}()
end

function Base.:(==)(a::DatasetEntry, b::DatasetEntry)
    if typeof(a) != typeof(b)
        return false
    end
    for field in fieldnames(typeof(a))
        if (field in [:checksum, :skip_checksum])
            continue
        end
        if getfield(a, field) != getfield(b, field)
            return false
        end
    end
    return true
end

# Checksum accessors over the stored `checksum = "<algo>:<hex>"` field.
"The checksum's algorithm (`sha256` for a bare/empty-prefixed value), or `\"\"`."
function hash_algo(entry::DatasetEntry)
    c = getfield(entry, :checksum)
    isempty(c) && return ""
    parts = split(c, ':'; limit=2)
    return length(parts) == 2 ? String(parts[1]) : "sha256"
end

"The checksum's hex digest (without the `algo:` prefix), or `\"\"`."
function hash_value(entry::DatasetEntry)
    c = getfield(entry, :checksum)
    isempty(c) && return ""
    parts = split(c, ':'; limit=2)
    return length(parts) == 2 ? String(parts[2]) : c
end

# Back-compat property: `entry.sha256` reads the hex when the algorithm is sha256
# (else `""`), and `entry.sha256 = hex` stores `checksum = "sha256:<hex>"`. Every
# other field falls through to the normal getfield/setfield!.
function Base.getproperty(entry::DatasetEntry, name::Symbol)
    if name === :sha256
        return hash_algo(entry) in ("", "sha256") ? hash_value(entry) : ""
    end
    return getfield(entry, name)
end

function Base.setproperty!(entry::DatasetEntry, name::Symbol, value)
    if name === :sha256
        return setfield!(entry, :checksum, isempty(value) ? "" : "sha256:" * String(value))
    end
    # Mirror Julia's default setproperty!, which converts to the field type (so a
    # SubString assigned to a String field is coerced, etc.).
    return setfield!(entry, name, convert(fieldtype(DatasetEntry, name), value))
end

function build_dataset_key(entry::DatasetEntry, path::String="")
    clean_path = strip(path == "" ? entry.path : path, '/')
    key = joinpath(entry.host, clean_path)
    if (entry.version !== "")
        key = key * "#$(entry.version)"
    end
    return strip(key, '/')
end

"""
Infer file format from the dataset key (e.g. \"data/out.csv\" -> \"csv\", \"archive.tar.gz\" -> \"tar.gz\").
Strips any version # fragment before taking the extension.
"""
function guess_file_format(entry::DatasetEntry)
    key = rstrip(entry.key, '/')
    # Trim version suffix (e.g. host/path#v1.0 -> host/path)
    if occursin('#', key)
        key = split(key, '#'; limit=2)[1]
    end
    isempty(key) && return ""
    base, ext = splitext(key)
    if ext == ".gz"
        base, ext2 = splitext(base)
        if ext2 == ".tar"
            ext = ext2 * ext
        end
    end
    return lstrip(ext, '.')
end

# Render a Julia binding (ref + optional args/kwargs) for `[<ds>._LANG.julia]`.
# With no args and no kwargs it is a bare `module:function` string (conventional
# call); otherwise a `{ ref, args, kwargs }` table (kwargs keys are sorted by the
# TOML writer, args order preserved).
function _binding_to_dict(ref::AbstractString, args, kwargs)
    if isempty(args) && isempty(kwargs)
        return String(ref)
    end
    t = Dict{String,Any}("ref" => String(ref))
    if !isempty(args)
        t["args"] = args
    end
    if !isempty(kwargs)
        t["kwargs"] = kwargs
    end
    return t
end

function to_dict(entry::DatasetEntry)
    output = Dict{String,Any}()
    for field in fieldnames(typeof(entry))
        if (field in HIDE_STRUCT_FIELDS)
            continue
        end
        if (field == :extra)
            continue
        end
        # Parsed own Julia bindings (refs + args/kwargs payloads) are regenerated
        # under `[<ds>._LANG.julia]` below, never emitted as flat scalar keys.
        if (field in (:lang_julia_fetcher, :lang_julia_loader,
                      :lang_julia_fetcher_args, :lang_julia_fetcher_kwargs,
                      :lang_julia_loader_args, :lang_julia_loader_kwargs))
            continue
        end
        value = getfield(entry, field)
        if (value === nothing || value == [] || value == Dict() || value === "" || value == false)
            continue
        end
        if (field == :uri)
            # A content-free `build_uri` artifact ("://" — no scheme/host/path)
            # carries no information, and emitting it corrupts the re-parsed key on
            # round-trip (it parses back to ":"), colliding key-less entries
            # (e.g. a produced table or a `local_path`-only dataset). Drop it.
            if value == "://"
                continue
            end
        end
        if (field == :key)
            if value == build_dataset_key(entry)
                continue
            end
        end
        if (field == :format)
            if value == guess_file_format(entry)
                continue
            end
        end
        output[String(field)] = value
    end
    # Splice unknown per-dataset keys / foreign `_*` sub-tables back verbatim.
    for (k, v) in entry.extra
        output[String(k)] = v
    end
    # Regenerate the own `[<ds>._LANG.julia]` block (fetcher/loader refs) from the
    # parsed fields and merge it with any foreign `_LANG.<other>` subtrees kept
    # verbatim in `extra`. The Julia subtable is regenerated; foreign subtrees are
    # copied as-is (the splice above already placed them under `output["_LANG"]`).
    julia_block = Dict{String,Any}()
    if entry.lang_julia_fetcher != ""
        julia_block["fetcher"] = _binding_to_dict(
            entry.lang_julia_fetcher, entry.lang_julia_fetcher_args,
            entry.lang_julia_fetcher_kwargs)
    end
    if entry.lang_julia_loader != ""
        julia_block["loader"] = _binding_to_dict(
            entry.lang_julia_loader, entry.lang_julia_loader_args,
            entry.lang_julia_loader_kwargs)
    end
    if !isempty(julia_block)
        lang = (haskey(output, "_LANG") && output["_LANG"] isa AbstractDict) ?
            copy(output["_LANG"]) : Dict{String,Any}()
        lang["julia"] = julia_block
        output["_LANG"] = lang
    end
    return output
end

function Base.string(x::DatasetEntry)
    return "$(typeof(x)):\n$(join(("- $k=$(string(v))" for (k, v) in pairs(to_dict(x))),"\n"))"
end

function Base.show(io::IO, x::DatasetEntry)
    print(io, Base.string(x))
end

function string_short(x::DatasetEntry)
    return x.key
end

function trimstring(s::String, n::Int; path=true)
    if length(s) <= n
        return s
    end
    if !path
        return s[1:n] * "..."
    end
    while length(s) > n
        parts = splitpath(s)
        if length(parts) <= 1
            return s
        end
        s = joinpath(parts[1:end-1])
    end
    return s * "..."
end

function Base.repr(x::DatasetEntry)
    return "$(typeof(x))($(join(("$k=$(trimstring(repr(v), 30))" for (k, v) in pairs(to_dict(x))), ", ")))"
end

function repr_short(x::DatasetEntry)
    s = "$(typeof(x))($(join(("$k=$(trimstring(repr(v), 50))" for (k, v) in pairs(to_dict(x)) if k in ["uri"]), ", "))...)"
    return replace(s, "......" => "...")
end

function Base.show(io::IO, ::MIME"text/plain", x::DatasetEntry)
    print(io, Base.repr(x))
end

mutable struct Database
    datasets::Dict{String,<:DatasetEntry}
    datasets_toml::String
    datasets_folder::String
    skip_checksum::Bool
    skip_checksum_folders::Bool
    loaders::Dict{String,String}
    loaders_julia_modules::Vector{String}
    loaders_julia_includes::Vector{String}
    loader_cache::Dict{String,Function}
    loader_context_module::Union{Module,Nothing}
    # Unknown top-level `_*` tables (`_META`, foreign `_LANG.<other>`, future
    # `_FOO`) kept verbatim for lossless round-trip. The own top-level
    # `[_LANG.julia]` subtable is consumed into `lang_julia_loaders` and removed
    # from here; every foreign top-level `[_LANG.<other>]` stays verbatim.
    extra::Dict{String,Any}
    # Schema version from `[_META].schema`; `nothing` ⇒ v0 (legacy flat).
    schema::Union{Int,Nothing}
    # Own v1 default loaders parsed from `[_LANG.julia.loaders]`: a `format → binding`
    # map (spec-v3.3 — each binding is a `module:function` string or a `{ ref, args,
    # kwargs }` table, exactly like a per-dataset loader). Empty ⇒ none declared.
    lang_julia_loaders::Dict{String,Any}
    # Parsed copy of `[_STORAGE]` for the path resolver; verbatim copy stays in
    # `extra` for lossless round-trip. Empty when `[_STORAGE]` is absent.
    storage_config::Dict{String,Any}
    # Frozen configuration snapshot (the full ladder inputs — file layers, env,
    # host — captured at materialization by `freeze_config!`); `nothing` until
    # then, frozen lazily on first use for a directly-constructed Database.
    config::Union{ConfigSnapshot,Nothing}

    function Database(datasets::Dict{String,<:DatasetEntry},
            datasets_toml::String,
            datasets_folder::String,
            skip_checksum::Bool,
            skip_checksum_folders::Bool,
            loaders::Dict{String,String},
            loaders_julia_modules::Vector{String},
            loaders_julia_includes::Vector{String},
            loader_cache::Dict{String,Function},
            loader_context_module::Union{Module,Nothing},
            extra::Dict{String,Any}=Dict{String,Any}(),
            schema::Union{Int,Nothing}=nothing,
            lang_julia_loaders::Dict{String,Any}=Dict{String,Any}(),
            storage_config::Dict{String,Any}=Dict{String,Any}(),
            config::Union{ConfigSnapshot,Nothing}=nothing)
        new(datasets, datasets_toml, datasets_folder, skip_checksum, skip_checksum_folders,
            loaders, loaders_julia_modules, loaders_julia_includes, loader_cache, loader_context_module,
            extra, schema, lang_julia_loaders, storage_config, config)
    end
end

# Mutating a snapshot input (the manifest layer, or the manifest path that
# anchors the checkout-config lookup) invalidates the frozen config; it is
# re-frozen lazily on next use (see `freeze_config!`).
function Base.setproperty!(db::Database, name::Symbol, value)
    (name === :storage_config || name === :datasets_toml) &&
        setfield!(db, :config, nothing)
    return setfield!(db, name, convert(fieldtype(Database, name), value))
end

function Base.:(==)(db1::Database, db2::Database)
    return db1.datasets == db2.datasets && db1.datasets_folder == db2.datasets_folder &&
           db1.datasets_toml == db2.datasets_toml && db1.loaders == db2.loaders &&
           db1.loaders_julia_modules == db2.loaders_julia_modules &&
           db1.loaders_julia_includes == db2.loaders_julia_includes &&
           db1.extra == db2.extra && db1.schema == db2.schema
end

# Consider a value empty for TOML output (do not write key)
_is_empty_toml(value) = value === nothing || value === "" || value == [] || value == false || value == Dict()

function to_dict(db::Database; kwargs...)
    loaders_table = Dict{String,Any}()
    if !_is_empty_toml(db.loaders_julia_modules)
        loaders_table["julia_modules"] = db.loaders_julia_modules
    end
    if !_is_empty_toml(db.loaders_julia_includes)
        loaders_table["julia_includes"] = db.loaders_julia_includes
    end
    for (n, c) in pairs(db.loaders)
        if !_is_empty_toml(c)
            loaders_table[n] = c
        end
    end
    result = Dict{String,Any}()
    if !isempty(loaders_table)
        result["_LOADERS"] = loaders_table
    end
    # Splice unknown top-level `_*` tables (`_META`, foreign `_LANG.<other>`,
    # future `_FOO`) back verbatim.
    for (k, v) in pairs(db.extra)
        result[String(k)] = v
    end
    # Regenerate the own top-level `[_LANG.julia]` block (the `loaders` format→ref
    # map) from the parsed model and merge it with any foreign top-level
    # `[_LANG.<other>]` kept verbatim in `db.extra` (already spliced above).
    if !isempty(db.lang_julia_loaders)
        # Canonical write (spec-v3.3): a ref-only binding emits the bare string, a
        # parameterized one a `{ ref, args, kwargs }` table — via the same normalization
        # as per-dataset bindings.
        julia_block = Dict{String,Any}(
            "loaders" => Dict{String,Any}(
                k => _binding_to_dict(_parse_binding(v)...) for (k, v) in db.lang_julia_loaders),
        )
        lang = (haskey(result, "_LANG") && result["_LANG"] isa AbstractDict) ?
            copy(result["_LANG"]) : Dict{String,Any}()
        lang["julia"] = julia_block
        result["_LANG"] = lang
    end
    for (key, entry) in pairs(db.datasets)
        result[key] = to_dict(entry; kwargs...)
    end
    return result
end

function Base.show(io::IO, db::Database)
    print(io, "$(typeof(db))")
    if length(db.datasets) == 0
        print(io, " (Empty)\n")
    else
        print(io, ":\n")
    end
    for (k, v) in pairs(db.datasets)
        s = "- $k => $(string_short(v))"
        s = trimstring(s, 80; path=false)
        print(io, s*"\n")
    end
    print(io, "datasets_folder: $(db.datasets_folder)\n")
    if db.datasets_toml != ""
        print(io, "datasets_toml: $(db.datasets_toml)")
    else
        print(io, "datasets_toml: $(repr(db.datasets_toml)) (in-memory database)")
    end
end

function Base.show(io::IO, ::MIME"text/plain", db::Database)
    print(io, "$(typeof(db))(\n")
    print(io, "  datasets=Dict(\n")
    for (k, v) in pairs(db.datasets)
        print(io, "    $k => ", repr_short(v), ",\n")
    end
    print(io, "  ),\n")
    print(io, "  datasets_folder=$(repr(db.datasets_folder))\n")
    if db.datasets_toml != ""
        print(io, "  datasets_toml=$(repr(db.datasets_toml))\n)")
    else
        print(io, "  datasets_toml=\"\" (in-memory database)\n)")
    end
end

# Canonical key order (matches the Python tool's `Database.write`): structural
# `_*` tables (`_META`, `_LANG`, `_LOADERS`, `_STORAGE`) first, then datasets —
# both alphabetical. A plain code-point sort would drop `_` (0x5F) *between*
# the upper-cased / digit-named datasets and the lower-cased ones.
_toml_sort_key(k) = (startswith(String(k), "_") ? 0 : 1, String(k))

function TOML.print(io::IO, db::Database; sorted=true, by=_toml_sort_key, kwargs...)
    return TOML.print(io, to_dict(db); sorted=sorted, by=by, kwargs...)
end

function TOML.print(db::Database; sorted=true, by=_toml_sort_key, kwargs...)
    return TOML.print(to_dict(db); sorted=sorted, by=by, kwargs...)
end

# Locate the Python `datamanifest` CLI: the project-local venv next to the
# manifest first (`<dir>/.venv/bin/datamanifest`), then — when the manifest
# sits inside a linked `git worktree`, which starts without the project's
# `.venv` — the corresponding directory in the main checkout, then PATH.
function _find_datamanifest_cli(datasets_toml::String)
    if datasets_toml != ""
        bindir = Sys.iswindows() ? "Scripts" : "bin"
        exename = Sys.iswindows() ? "datamanifest.exe" : "datamanifest"
        dir = dirname(abspath(datasets_toml))
        venv_exe = joinpath(dir, ".venv", bindir, exename)
        isfile(venv_exe) && return venv_exe
        main = _main_checkout_dir(dir)
        if main != ""
            venv_exe = joinpath(main, ".venv", bindir, exename)
            isfile(venv_exe) && return venv_exe
        end
    end
    return Sys.which("datamanifest")
end


# Warn only once per session when DATAMANIFEST_CANONICAL is set but the CLI is
# missing — persisting happens after every registration and would spam otherwise.
const _canonical_cli_missing_warned = Ref(false)

# Pipe a TOML string through the Python `datamanifest format` CLI to obtain the
# canonical, cross-tool byte-identical serialization (the same recursive-sorted
# `tomli_w` output the Python tool writes). Graceful: if the call fails, fall
# back to the native string — which is *semantically* identical (same keys,
# same canonical order), differing only in TOML-library formatting
# (indentation, blank lines, inline-vs-multiline arrays) — with a warning.
function _canonicalize_toml(toml_string::String, exe::String)::String
    try
        out = IOBuffer()
        run(pipeline(`$exe format`; stdin=IOBuffer(toml_string), stdout=out))
        return String(take!(out))
    catch e
        warn("write(...; canonical=true): `datamanifest format` failed ($e); writing native TOML.")
        return toml_string
    end
end

function write(db::Database, datasets_toml::String; canonical::Union{Bool,Nothing}=nothing, kwargs...)
    toml_string = sprint(TOML.print, db; kwargs...)
    if (toml_string === nothing)
        error("Failed to convert Database to TOML string.")
    end
    explicit = canonical !== nothing
    if explicit ? canonical : canonical_write(storage_config=storage_layers(db))
        exe = _find_datamanifest_cli(datasets_toml)
        if exe === nothing
            if explicit || !_canonical_cli_missing_warned[]
                _canonical_cli_missing_warned[] = true
                warn("canonical TOML output: the `datamanifest` (Python) CLI was found neither " *
                     "next to the manifest (.venv) nor on PATH; writing native TOML " *
                     "(semantically identical; cross-tool byte-identity needs the peer CLI).")
            end
        else
            toml_string = _canonicalize_toml(toml_string, exe)
        end
    end
    open(datasets_toml, "w") do io
        Base.write(io, toml_string)
    end
end

function set_datasets_folder(db::Database, path::String)
    db.datasets_folder = path
end

function set_datasets(db::Database, datasets::Dict{String,<:DatasetEntry})
    db.datasets = datasets
end

function get_datasets_folder(db::Database, datasets_folder::String="")
    if datasets_folder != ""
        return datasets_folder
    end
    return db.datasets_folder
end

function get_datasets_toml(db::Database, datasets_toml::String="")
    if datasets_toml !== ""
        return datasets_toml
    end
    return db.datasets_toml
end

function get_datasets(db::Database)
    return db.datasets
end

# ----- PathUri -----
function parse_uri_metadata(uri::String)
    if startswith(uri, "git@")
        scheme = "git"
        uri = replace(uri, ":" => "/")
        uri = replace(uri, "git@" => "git://")
    end
    parsed = URI(uri)
    host = String(parsed.host)
    scheme = String(parsed.scheme)
    path = rstrip(String(parsed.path), '/')
    fragment = String(parsed.fragment)
    query = queryparams(parsed)
    version = get(query, "version", "")
    ref = get(query, "ref", "")
    format = get(query, "format", "")
    return (
        uri=uri,
        scheme=scheme,
        host=host,
        path=path,
        format=format,
        version=fragment !== "" ? fragment : (version !=="" ? version : ref),
    )
end

function get_dataset_key(entry::DatasetEntry)
    if entry.key !== ""
        return entry.key
    end
    return build_dataset_key(entry)
end

# Resolve the directory under which an entry's `<key>` lives (spec-v3). A blank `store`
# falls back to the project-wide `default` selector (itself defaulting to `$data`). The
# fetched path composes selector + the `datasets/` content prefix + (optional) datasets
# scope: `<root>[/subpath]/datasets/[<scope>/]<key>`. An explicitly-provided
# `datasets_folder` (non-empty) is used verbatim for the `$data` selector (back-compat —
# an exact folder, no prefix/scope).
function get_dataset_path(entry::DatasetEntry, datasets_folder::String=""; extract::Union{Bool,Nothing}=nothing, project_root::String="", storage_config::ConfigLike=Dict{String,Any}())
    # spec-v4: one location per dataset — the `storage_path` field (default `$datasets_dir/$key`).
    # `lazy_access` opens the `uri` in place (spec-v4.3); `skip_download` (with no explicit path)
    # returns the documented `uri` verbatim. Both yield the `uri` as the "path".
    if (entry.lazy_access || (entry.skip_download && entry.storage_path == ""))
        return entry.uri
    end
    if (extract === nothing)
        extract = entry.extract
    end
    key = extract ? get_extract_path(entry.key) : entry.key
    return dataset_storage_path(entry.storage_path, key; project_root=project_root,
        storage_config=storage_config, datasets_folder=datasets_folder)
end

"""
    freeze_config!(db) -> db

Capture the database's configuration snapshot: the full resolution-ladder inputs —
the checkout config (`.datamanifest/config.toml`), the manifest's `[_STORAGE]`, the
user-global config, **and** the environment and host — frozen together. Runs at
materialization, so every config variable has one well-defined value for the
Database's lifetime; call it again to re-read the config files and environment for
an existing Database.
"""
function freeze_config!(db::Database)
    db.config = ConfigSnapshot(
        config_layers(db.storage_config; project_root=get_project_root(db)),
        Dict{String,String}(ENV),
        gethostname())
    return db
end

# The database's frozen configuration snapshot (the spec-v5 chain + env + host),
# captured at materialization; frozen on first use for a directly-constructed db.
function storage_layers(db::Database)::ConfigSnapshot
    db.config === nothing && freeze_config!(db)
    return db.config
end

function get_dataset_path(db::Database, entry::DatasetEntry; kwargs...)
    return get_dataset_path(entry, get_datasets_folder(db); project_root=get_project_root(db), storage_config=storage_layers(db), kwargs...)
end

function get_dataset_path(db::Database, name::String; extract=nothing, kwargs...)
    (name, dataset) = search_dataset(db, name; kwargs...)
    return get_dataset_path(dataset, get_datasets_folder(db); extract=extract, project_root=get_project_root(db), storage_config=storage_layers(db))
end

# Read-side resolution (spec-v4): a dataset has a single location — its `storage_path`
# (default `$datasets_dir/$key`). Return it; on a miss, fall back to the legacy read-only
# `~/.cache/Datasets/<key>` probe so old downloads still resolve, else the write path.
#
# Read-first resolution (spec-v4.1): the state file's recorded `storage_path` is consulted
# **before** the derived path, so a moved/relocated dataset is found where it really lives.
# The recorded path only helps *find* an existing object; a (re)download still writes to the
# derived directive location (the gold standard).

"""
    dataset_state_root(db) -> String

The directory whose `.datamanifest/state.toml` inventories this database's **fetched**
datasets: the manifest's directory for a persisted database; for an **in-memory** one
(`datasets_toml == ""`, e.g. `persist=false`) the resolved datasets root itself — the
explicit `datasets_folder` (path expressions expanded) when set, else the resolved
`datasets_dir` — so an in-memory database keeps its inventory under the storage root it
describes and never writes a state file into the caller's project / cwd.
"""
function dataset_state_root(db::Database)::String
    db.datasets_toml != "" && return dirname(db.datasets_toml)
    sc = storage_layers(db)
    proot = get_project_root(db)
    folder = db.datasets_folder
    isempty(folder) &&
        return datasets_dir(; project_root=proot, storage_config=sc)
    p = expand_path_expr(folder; project_root=proot, storage_config=sc)
    return isabspath(p) ? p : (isempty(proot) ? abspath(p) : joinpath(proot, p))
end

# The state-file reader lives in the sibling `Cache` module (loaded after this one); reached
# at runtime via the parent package. Returns `entry`'s recorded resolved location (absolute,
# relative records anchored to the project root), or "" when unrecorded / unavailable.
function _state_recorded_dataset_path(db::Database, entry::DatasetEntry)::String
    base = dataset_state_root(db)
    isempty(base) && return ""
    C = try; getfield(parentmodule(@__MODULE__), :Cache); catch; return ""; end
    sp = try
        sf = C.locate_state(base)
        isfile(sf) ? C.dataset_path_of(C.read_index(sf), entry.key) : ""
    catch
        ""
    end
    isempty(sp) && return ""
    isabspath(sp) && return sp
    root = get_project_root(db)
    return abspath(joinpath(isempty(root) ? base : root, sp))
end

# Render `path` for the state file: relative to the project root when it lives under it
# (portable across clones), absolute otherwise — mirroring the produced-artifact convention.
function _portable_storage_path(path::AbstractString, project_root::AbstractString)::String
    if !isempty(project_root)
        ap, rt = abspath(path), abspath(project_root)
        (ap == rt || startswith(ap, rt * "/")) && return relpath(ap, rt)
    end
    return String(path)
end

"""
    record_dataset_state(db, entry, path)

Record a fetched dataset's resolved `path` (+ its actual `sha256` unless checksums are
skipped) into the database's state file — the inventory of where every object lives.
Additive and concurrency-safe (re-read + merge + atomic write). Best-effort: a read-only /
unwritable state file never breaks a download.

The state file anchors at [`dataset_state_root`](@ref): the project (manifest) directory for
a persisted database; for an **in-memory** database the resolved datasets root itself
(`<datasets_root>/.datamanifest/state.toml`), recorded with absolute paths — nothing is
written outside directories the database explicitly owns.
"""
function record_dataset_state(db::Database, entry::DatasetEntry, path::AbstractString)
    (isempty(path) || isempty(entry.key)) && return nothing
    base = dataset_state_root(db)
    isempty(base) && return nothing
    C = try; getfield(parentmodule(@__MODULE__), :Cache); catch; return nothing; end
    try
        idx = C.read_index_or_empty(base)
        # In-memory: the inventory lives under the datasets root, not the project — record
        # the location absolute (project-relative rendering would mis-anchor on read-back).
        sp = db.datasets_toml != "" ? _portable_storage_path(path, get_project_root(db)) :
            abspath(path)
        sha = (db.skip_checksum || entry.skip_checksum) ? "" : entry.sha256
        C.register_dataset!(idx; key=entry.key, storage_path=sp, sha256=sha)
        C.write_index(idx)
    catch
    end
    return nothing
end

function resolve_existing_path(db::Database, entry::DatasetEntry; extract::Union{Bool,Nothing}=nothing)
    p = get_dataset_path(db, entry; extract=extract)
    # A user-managed exact path (storage_path without `$key`), a skip_download URI, or a
    # lazy_access (in-place) URI is fixed — no read-first / pool probing.
    user_managed = entry.storage_path != "" && !occursin("\$key", entry.storage_path)
    (entry.skip_download || entry.lazy_access || user_managed) && return p
    # Read-first: a recorded location whose bytes are actually present wins (a moved dataset).
    # The recorded storage_path is the location the dataset is normally read from — the
    # extracted dir for an extract-ed dataset, the file otherwise — so read-first applies at
    # that NATURAL level (a caller asking for the other level gets the derived path).
    eff_extract = extract === nothing ? entry.extract : extract
    if eff_extract == entry.extract
        rec = _state_recorded_dataset_path(db, entry)
        (!isempty(rec) && rec != abspath(p) && ispath(rec)) && return rec
    end
    return p
end

"""
    resolve_from_pools(db, entry; extract=nothing) -> String

A **read pool** (Python-parity, ahead of the spec) that already holds this dataset's bytes,
or `""`. `[_STORAGE].datasets_pools` (host-composable, defaulting to well-known machine-wide
locations — `\$user_data_dir/datamanifest/datasets`, `~/.cache/Datasets`) are extra read-only
directories probed for the location the dataset is read from — so a dataset another project
already fetched is reused in place instead of re-downloaded. For an `extract`-ed dataset the
**extracted** location `<pool>/<extract_path>` is probed (that is what it is read from, and
what its `sha256` hashes — this tool checksums the extracted dir, not the archive). A declared
`sha256` is **verified** against the pooled copy; a present-but-mismatched copy is **warned**
about (the manifest checksum may be stale) and not adopted, and the next pool is tried. The
pool is never written to; the caller records the adopted location, and the gold standard (new
downloads → `datasets_dir`) is unchanged. Skipped for `skip_download` / user-managed datasets.
"""
function resolve_from_pools(db::Database, entry::DatasetEntry; extract::Union{Bool,Nothing}=nothing)::String
    user_managed = entry.storage_path != "" && !occursin("\$key", entry.storage_path)
    (entry.skip_download || entry.lazy_access || user_managed) && return ""
    eff_extract = extract === nothing ? entry.extract : extract
    # The probed location matches what the dataset is read from / checksummed: the extracted
    # dir for an extract dataset, the file otherwise.
    probe_key = eff_extract ? get_extract_path(entry.key) : entry.key
    algo = hash_algo(entry)
    declared = !isempty(entry.checksum) && hashable_algo(algo) &&
               !(db.skip_checksum || entry.skip_checksum)
    pools = datasets_pools(; project_root=get_project_root(db), storage_config=storage_layers(db))
    for pool in pools
        cand = joinpath(pool, probe_key)
        (isfile(cand) || isdir(cand)) || continue
        if declared
            actual = try; hash_path(cand, algo); catch; nothing; end
            actual === nothing && continue
            if actual != hash_value(entry)
                # Present in the pool but its checksum disagrees — surface it (the manifest
                # checksum may be stale) rather than silently skip.
                warn("Found $(entry.key) in read pool at $cand but its checksum does not match " *
                     "(manifest $(first(entry.checksum, 18))…, on disk $(first(actual, 12))…); " *
                     "not adopted. Update/clear the manifest checksum or set skip_checksum if stale.")
                continue
            end
        end
        return cand
    end
    return ""
end

function build_uri(meta::DatasetEntry)
    uri = meta.uri !== "" ? meta.uri : ""
    if uri == ""
        uri = "$(meta.scheme)://$(meta.host)"
        if meta.path !== ""
            uri *= "/$(strip(meta.path, '/'))"
        end
        if meta.version !== ""
            uri *= "#$(meta.version)"
        end
    end
    return uri
end

# One-time deprecation flag: fires the first time a v0/legacy form is read.
const _LEGACY_DEPRECATION_WARNED = Ref{Bool}(false)

function _warn_legacy_once()
    _LEGACY_DEPRECATION_WARNED[] && return
    _LEGACY_DEPRECATION_WARNED[] = true
    warn("Legacy manifest form detected (flat julia=/loader= fields or [_LOADERS] table). " *
         "Call DataManifest.migrate(path) to update to v1 _LANG format.")
end

# One-time flag: fires the first time a dataset resolves from the legacy
# read-only datasets folder ($XDG_CACHE_HOME/Datasets, the pre-v1.1 default).
const _LEGACY_DIR_WARNED = Ref{Bool}(false)

function _warn_legacy_dir_once()
    _LEGACY_DIR_WARNED[] && return
    _LEGACY_DIR_WARNED[] = true
    legacy = legacy_data_root()
    warn("Reading datasets from the legacy location $legacy (pre-v1.1 default; read-only). " *
         "spec-v5 fetches into the resolved datasets_dir (default the shared store " *
         "\$user_data_dir/datamanifest/shared/datasets; the legacy folder is also a default " *
         "read pool). To keep using " *
         "the legacy folder, set DATAMANIFEST_DATASETS_DIR=$legacy; otherwise migrate it " *
         "manually (e.g. with rsync) at your convenience.")
end

# True when a string looks like a `Module[.Sub]:function` ref: no whitespace,
# no newlines — safe to resolve via getfield without include_string.
function _is_ref(s::String)::Bool
    return occursin(r"^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_]*$", s)
end

# Split a `_LANG` table into its own `julia` subtable (or `nothing`) and a
# dict of every foreign `_LANG.<other>` entry kept verbatim. The own Julia
# subtable is consumed into the model; the foreign remainder stays in `extra`.
function _split_lang(lang)
    julia = nothing
    foreign = Dict{String,Any}()
    if lang isa AbstractDict
        for (k, v) in lang
            if String(k) == "julia"
                julia = v
            else
                foreign[String(k)] = v
            end
        end
    end
    return julia, foreign
end

# Parse a dataset's own `[<ds>._LANG.julia]` (fetcher/loader refs) into the
# model and drop it from `entry.extra`; keep every foreign `_LANG.<other>`
# subtree verbatim. Legacy entries (no `_LANG`) are untouched.
# Decompose a fetcher/loader binding into `(ref, args, kwargs)`. A bare string is
# `ref` with empty args/kwargs; a `{ ref, args, kwargs }` table pulls each part
# (args order preserved; kwargs keys stringified). Anything else ⇒ empty ref.
function _parse_binding(b)
    if b isa AbstractString
        return String(b), Any[], Dict{String,Any}()
    elseif b isa AbstractDict
        ref = get(b, "ref", nothing)
        ref = ref isa AbstractString ? String(ref) : ""
        a = get(b, "args", nothing)
        args = a isa AbstractVector ? collect(Any, a) : Any[]
        kw = get(b, "kwargs", nothing)
        kwargs = kw isa AbstractDict ?
            Dict{String,Any}(String(k) => v for (k, v) in kw) : Dict{String,Any}()
        return ref, args, kwargs
    end
    return "", Any[], Dict{String,Any}()
end

function _parse_dataset_lang!(entry::DatasetEntry)
    haskey(entry.extra, "_LANG") || return entry
    julia, foreign = _split_lang(entry.extra["_LANG"])
    if julia isa AbstractDict
        f = get(julia, "fetcher", nothing)
        l = get(julia, "loader", nothing)
        if f isa AbstractString || f isa AbstractDict
            entry.lang_julia_fetcher, entry.lang_julia_fetcher_args,
                entry.lang_julia_fetcher_kwargs = _parse_binding(f)
        end
        if l isa AbstractString || l isa AbstractDict
            entry.lang_julia_loader, entry.lang_julia_loader_args,
                entry.lang_julia_loader_kwargs = _parse_binding(l)
        end
    end
    if isempty(foreign)
        delete!(entry.extra, "_LANG")
    else
        entry.extra["_LANG"] = foreign
    end
    return entry
end

# Parse the top-level `[_LANG.julia.loaders]` (format→ref map) into the model
# and drop the own `julia` subtable from `db.extra`; keep every foreign
# top-level `[_LANG.<other>]` verbatim.
function _parse_database_lang!(db::Database)
    haskey(db.extra, "_LANG") || return db
    julia, foreign = _split_lang(db.extra["_LANG"])
    if julia isa AbstractDict
        loaders = get(julia, "loaders", nothing)
        if loaders isa AbstractDict
            for (fmt, b) in loaders
                # spec-v3.3: a project loader is a binding (string or `{ ref, … }` table);
                # keep it raw for lossless round-trip + parameterized resolution.
                if b isa AbstractString
                    db.lang_julia_loaders[String(fmt)] = String(b)
                elseif b isa AbstractDict
                    db.lang_julia_loaders[String(fmt)] = Dict{String,Any}(String(k) => v for (k, v) in b)
                end
            end
        end
    end
    if isempty(foreign)
        delete!(db.extra, "_LANG")
    else
        db.extra["_LANG"] = foreign
    end
    return db
end

# Put the manifest's directory (the project root) on the module load path so
# `module:function` refs naming local modules resolve by convention (Julia
# treats a directory on LOAD_PATH as an implicit environment). Idempotent;
# only applies to file-backed databases.
function _ensure_project_root_on_load_path(db::Database)
    db.datasets_toml == "" && return nothing
    root = get_project_root(db)
    if !isempty(root) && isdir(root) && !(root in LOAD_PATH)
        push!(LOAD_PATH, root)
    end
    return nothing
end

function init_dataset_entry(;
    downloads::Vector{String}=Vector{String}(),
    ref::String="",
    uri=nothing,
    uris=nothing,
    kwargs...)

    # Normalize: uri can be a Vector (same as uris)
    if uri isa AbstractVector
        if uris !== nothing && !isempty(uris)
            error("Cannot provide both `uri` as a list and `uris`")
        end
        uris = String.(uri)
        uri = ""
    end
    if uri === nothing
        uri = ""
    end
    if uris === nothing
        uris = String[]
    else
        uris = String.(uris)
    end

    # Checksum: accept the legacy `sha256 = "<hex>"` key and a bare-hex `checksum`,
    # normalizing both to `checksum = "sha256:<hex>"` (an explicit `checksum` wins).
    # This is the read half of the migration: the entry is re-emitted as `checksum`
    # on the next write.
    kw = Dict{Symbol,Any}(kwargs)
    legacy_sha = pop!(kw, :sha256, nothing)
    chk = get(kw, :checksum, nothing)
    if chk !== nothing && chk != ""
        if !occursin(':', String(chk))
            kw[:checksum] = "sha256:" * String(chk)
        end
    elseif legacy_sha !== nothing && legacy_sha != ""
        kw[:checksum] = "sha256:" * String(legacy_sha)
    end

    # Separate known struct fields from unknown keys; unknown per-dataset keys
    # (scalars and foreign `_*` sub-tables) are kept verbatim in `entry.extra`.
    known = Set(fieldnames(DatasetEntry))
    passthrough = Dict{String,Any}()
    explicit_extra = nothing
    entry_kw = Pair{Symbol,Any}[]
    for (k, v) in kw
        if k === :extra
            explicit_extra = v
        elseif k in known
            push!(entry_kw, k => v)
        else
            passthrough[String(k)] = v
        end
    end

    for (k, v) in entry_kw
        if k in (:julia, :loader, :julia_modules, :julia_includes)
            nonempty = v isa AbstractString ? !isempty(v) : (v isa AbstractVector ? !isempty(v) : false)
            nonempty && (_warn_legacy_once(); break)
        end
    end
    entry = DatasetEntry(; uri=uri, uris=uris, entry_kw...)
    if explicit_extra !== nothing
        for (k, v) in pairs(explicit_extra)
            passthrough[String(k)] = v
        end
    end
    entry.extra = passthrough
    # Parse own `[<ds>._LANG.julia]` bindings (v1); keep foreign `_LANG.<other>`.
    _parse_dataset_lang!(entry)

    # Multiple-URI entry: key derived from common host + path prefix if not given
    if !isempty(entry.uris)
        if entry.key == ""
            parsed_list = [parse_uri_metadata(u) for u in entry.uris]
            host = parsed_list[1].host
            dir_segs = [filter(!isempty, split(p.path, '/'))[1:end-1] for p in parsed_list]
            n_common = 0
            if !isempty(dir_segs) && !isempty(dir_segs[1])
                for i in 1:length(dir_segs[1])
                    all(length(s) >= i && s[i] == dir_segs[1][i] for s in dir_segs) ? (n_common = i) : break
                end
            end
            common_path = join(dir_segs[1][1:n_common], '/')
            entry.key = isempty(common_path) ? host : "$host/$common_path"
        end
        return entry
    end

    if length(downloads) > 0
        warn("The `downloads` field is deprecated. Use `uri` instead.")
        if (entry.uri !== "")
            error("Cannot provide both uri and downloads")
        end
        if length(downloads) > 1
            error("Only one download URL is supported at the moment. Got: $(length(downloads))")
        end
        entry.uri = downloads[1]
    end
    if (entry.uri !== "")
        parsed = parse_uri_metadata(entry.uri)
        entry.host = parsed.host !== "" ? parsed.host : entry.host
        entry.path = parsed.path !== "" ? parsed.path : entry.path
        entry.scheme = parsed.scheme !== "" ? parsed.scheme : entry.scheme
        entry.format = parsed.format !== "" ? parsed.format : entry.format
        entry.version = parsed.version !== "" ? parsed.version : (entry.version !== "" ? entry.version : ref)
    else
        if entry.shell == "" && entry.julia == ""
            entry.uri = build_uri(entry)
        end
    end
    entry.key = entry.key !== "" ? entry.key : get_dataset_key(entry)
    if (entry.format == "")
        entry.format = guess_file_format(entry)
    else
        entry.format = lstrip(entry.format, '.')
    end
    entry.extract = entry.extract && (entry.format in COMPRESSED_FORMATS)
    if !isempty(entry.requires)
        entry.requires = String[String(r) for r in entry.requires]
    end
    if !isempty(entry.julia_modules)
        entry.julia_modules = String[String(m) for m in entry.julia_modules]
    end
    return entry
end

function is_a_git_repo(entry::DatasetEntry)
    segments = split(strip(entry.path, '/'), '/')
    if length(segments) < 2 || isempty(segments[1]) || isempty(segments[2])
        return false
    end
    app = split(entry.host, ".")[1]
    known_git_hosts = Set(["github.com", "bitbucket.org", "codeberg.org", "gitea.com", "sourcehut.org", "git.savannah.gnu.org", "git.kernel.org", "dev.azure.com"])
    if entry.host in known_git_hosts || app == "gitlab"
        return true
    else
        return false
    end
end

# ----- Registry -----
function _maybe_persist_database(db::Database, persist::Bool=true)
    if persist && db.datasets_toml != ""
        info("""Write database to $(length(db.datasets_toml) > 60 ? "..."  : "")$(db.datasets_toml[max(end-60, 1):end])""")
        write(db, db.datasets_toml)
    end
end

function verify_checksum(db::Database, dataset::DatasetEntry; persist::Bool=true, extract::Union{Nothing, Bool}=nothing, skip_if_complete::Bool=false)
    if (extract !== nothing && extract != dataset.extract)
        warn("dataset.extract=$(dataset.extract) but required extract=$extract. Skip verifying checksum.")
        return
    end
    local_path = get_dataset_path(db, dataset)
    if db.skip_checksum || dataset.skip_checksum
        return true
    end
    if (!isfile(local_path) && !isdir(local_path))
        return true
    end
    if (isdir(local_path) && db.skip_checksum_folders)
        return true
    end
    if skip_if_complete && dataset.checksum != "" && is_complete(local_path)
        return true
    end
    # An empty checksum is computed (and stored) as sha256; a declared checksum is
    # verified in its own algorithm and never silently rewritten to sha256. An
    # algorithm this implementation cannot compute (e.g. md5) is preserved but not
    # verified — warn and skip rather than erroring.
    if dataset.checksum == ""
        dataset.checksum = "sha256:" * sha256_path(local_path)
        _maybe_persist_database(db, persist)
        return true
    end
    algo = hash_algo(dataset)
    if !hashable_algo(algo)
        warn("Checksum algorithm '$algo' is not verifiable by this tool; " *
             "skipping verification for $(dataset.key).")
        return true
    end
    checksum = hash_path(local_path, algo)
    if hash_value(dataset) != checksum
        message = "Checksum mismatch for dataset at $local_path. Expected: $(dataset.checksum), got: $algo:$checksum. Possible resolutions:"
        message *= "\n- remove the file"
        message *= "\n- reset the `checksum` field"
        message *= "\n- use a different `key`"
        message *= "\n- remove Entry checksum checks (`dataset.skip_checksum = true`)"
        message *= "\n- remove Database checksum checks (`db.skip_checksum = true`)"
        error(message)
    end
end

function update_entry(db::Database, oldname::String, oldentry::DatasetEntry, newname::String, newentry::DatasetEntry;
    overwrite::Bool=false, persist::Bool=true)
    if (oldentry.key != newentry.key && oldentry.uri != newentry.uri && oldentry.version != newentry.version && oldname != newname)
        error("At least one the name or any of the following fields must match to update: key, uri")
    end
    if (oldentry == newentry && oldname == newname)
        info("Dataset entry [$newname] already exists.")
        return (oldname => oldentry)
    end
    verify_checksum(db, oldentry; persist=false)
    verify_checksum(db, newentry; persist=false)
    if (oldentry == newentry)
        if (! overwrite)
            error("Dataset entry already exists with name $oldname. Pass `overwrite=true` to update with new name $newname.")
        else
            warn("Rename $(oldname) => $(newname)")
            delete!(db.datasets, oldname)
            db.datasets[newname] = newentry
            _maybe_persist_database(db, persist)
            return (newname => newentry)
        end
    end
    message = "Possible duplicate found $oldname =>\n$oldentry"
    existing_datapath = get_dataset_path(db, oldentry)
    new_datapath = get_dataset_path(db, newentry)
    if (existing_datapath != new_datapath && (isfile(existing_datapath) | isdir(existing_datapath)))
        if (isfile(new_datapath) | isdir(new_datapath))
            message *= "\n\nBoth old and new datasets exist on disk at:"
            message *= "\n    $existing_datapath checksum: $(oldentry.checksum)"
            message *= "\n    $new_datapath checksum: $(newentry.checksum)"
        else
            message *= "\nExisting dataset found at\n    $existing_datapath\n."
        end
        message *= "\n\nCleanup manually if needed."
        message *= "Note you may explicitly specify the keys to point to a dataset, e.g.\n    key=\"$(oldentry.key)\"\n    key=\"$(newentry.key)\""
    end
    if (overwrite)
        warn("$message\n\nOverwriting with new entry $newname =>\n$newentry")
        if (haskey(db.datasets, oldname))
            delete!(db.datasets, oldname)
        end
        db.datasets[newname] = newentry
        _maybe_persist_database(db, persist)
        return (newname => newentry)
    else
        error("$message\n\nPlease manually remove the old entry or set `overwrite=true` to update with dataset $newname =>\n$newentry or pass `check_duplicate=false` to register nonetheless")
    end
end

function register_dataset(db::Database, uri::String="" ;
    name::String="",
    overwrite::Bool=false,
    persist::Bool=true,
    check_duplicate::Bool=true,
    kwargs...)
    entry = init_dataset_entry(; uri=uri, kwargs...)
    if (name == "")
        if is_a_git_repo(entry)
            name = join(split(strip(entry.path, '/'), '/')[1:2], '/')
        else
            name = strip(entry.key)
        end
        name = splitext(name)[1]
    end
    if check_duplicate
        existing_entry = search_dataset(db, entry.key; raise=false)
    else
        existing_entry = nothing
    end
    if (existing_entry !== nothing)
        return update_entry(db, existing_entry[1], existing_entry[2], name, entry; overwrite=overwrite, persist=persist)
    elseif haskey(db.datasets, name) && check_duplicate
        return update_entry(db, name, db.datasets[name], name, entry; overwrite=overwrite, persist=persist)
    end
    db.datasets[name] = entry
    if persist && db.datasets_toml != ""
        write(db, db.datasets_toml)
    end
    return (name => entry)
end

function register_dataset(db::Database, uris::Vector{String}; kwargs...)
    register_dataset(db, ""; uris=uris, kwargs...)
end

function _remove_dataset_from_disk(db::Database, entry::DatasetEntry)
    # Never delete a skip_download / lazy_access dataset or a user-managed exact `storage_path`.
    user_managed = entry.storage_path != "" && !occursin("\$key", entry.storage_path)
    if entry.skip_download || entry.lazy_access || user_managed
        return
    end
    download_path = get_dataset_path(db, entry; extract=false)
    if entry.extract
        local_path = get_dataset_path(db, entry; extract=true)
        if isdir(local_path)
            rm(local_path; force=true, recursive=true)
        end
    end
    if isfile(download_path)
        rm(download_path; force=true)
    elseif isdir(download_path)
        rm(download_path; force=true, recursive=true)
    end
end

function delete_dataset(db::Database, name::String; keep_cache::Bool=false, persist::Bool=true)
    (resolved_name, entry) = search_dataset(db, name)
    if !keep_cache
        _remove_dataset_from_disk(db, entry)
    end
    delete!(db.datasets, resolved_name)
    if persist && db.datasets_toml != ""
        write(db, db.datasets_toml)
    end
    return nothing
end

function extract_file(download_path, download_dir, format)
    mkpath(download_dir)
    if format == "zip"
        run(`unzip -o $download_path -d $download_dir`)
    elseif format == "tar.gz"
        run(`tar -xzf $download_path -C $download_dir`)
    elseif format == "tar"
        run(`tar -xf $download_path -C $download_dir`)
    else
        error("Unknown format: $format")
    end
end

function list_alternative_keys(dataset::DatasetEntry)
    alternatives = String[]
    if hasfield(typeof(dataset), :aliases)
        for alias in dataset.aliases
            push!(alternatives, alias)
        end
    end
    if dataset.doi !== ""
        push!(alternatives, dataset.doi)
    end
    push!(alternatives, dataset.key)
    push!(alternatives, dataset.path)
    if is_a_git_repo(dataset)
        repo_name = split(strip(dataset.path, '/'), '/')[2]
        push!(alternatives, repo_name)
    end
    unique_names = []
    for alt in alternatives
        if !isempty(alt) && !(alt in unique_names)
            push!(unique_names, alt)
        end
    end
    return unique_names
end

function list_dataset_keys(db::Database; alt=true, flat=false)
    entries = []
    for (name, dataset) in pairs(get_datasets(db))
        push!(entries, [name])
        if alt
            for key in list_alternative_keys(dataset)
                push!(entries[end], key)
            end
        end
    end
    if flat
        entries = cat(entries..., dims=1)
    end
    return entries
end

function repr_datasets(db::Database; alt=true)
    lines = [alt ? "Datasets including aliases:" : "Datasets:"]
    for keys in list_dataset_keys(db; alt=alt)
        push!(lines, "- " * join(keys, " | "))
    end
    return join(lines, "\n")
end

function print_dataset_keys(db::Database; alt=true)
    println(repr_datasets(db; alt=alt))
end

function search_datasets(db::Database, name::String ; alt=true, partial=false)
    datasets = get_datasets(db)
    matches = []
    in_results = (key -> key in Set(e[1] for e in matches))
    for (key, dataset) in pairs(datasets)
        if lowercase(key) == lowercase(name) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
    for (key, dataset) in pairs(datasets)
        if alt && lowercase(name) in map(lowercase, list_alternative_keys(dataset)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
    for (key, dataset) in pairs(datasets)
        if partial && occursin(lowercase(name), lowercase(key)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
    for (key, dataset) in pairs(datasets)
        if alt && partial && any(x -> occursin(lowercase(name), lowercase(x)), list_alternative_keys(dataset)) && !in_results(key)
            push!(matches, key => dataset)
        end
    end
    return matches
end

function search_dataset(db::Database, name::String; raise=true, kwargs...)
    results = search_datasets(db, name; kwargs...)
    if length(results) == 0
        if raise
            error("""No dataset found for: `$name`.
            Available datasets: $(join(keys(get_datasets(db)), ", "))
            $(repr_datasets(db))
            """)
        else
            return nothing
        end
    elseif (length(results) > 1)
        # spec-v4.3: identifier resolution is exact-or-error. A name/alias/doi matching more
        # than one dataset is a fail-loud error naming the candidates — never a silent
        # first-match (a `doi` may be shared by several datasets, so acting on an arbitrary one
        # is a correctness footgun).
        if raise
            cands = join([first(r) for r in results], ", ")
            error("Identifier `$name` matches multiple datasets: $cands. " *
                  "Disambiguate by exact name.")
        end
    end
    return results[1]
end

Base.getindex(db::Database, name::String) = search_dataset(db, name)[2]

function register_loaders(db::Database; loaders=nothing, julia_modules=nothing, julia_includes=nothing, persist::Bool=true)
    if loaders !== nothing
        db.loaders = Dict{String,String}(String(k) => (v isa String ? v : repr(v)) for (k, v) in pairs(loaders))
    end
    if julia_modules !== nothing
        db.loaders_julia_modules = String.(julia_modules)
    end
    if julia_includes !== nothing
        db.loaders_julia_includes = String.(julia_includes)
    end
    empty!(db.loader_cache)
    db.loader_context_module = nothing
    if persist && db.datasets_toml != ""
        write(db, db.datasets_toml)
    end
end

function validate_loader(db::Database, name::String)
    pipemod = parentmodule(@__MODULE__).PipeLines
    return pipemod._get_loader_function(db, name)
end

function validate_loaders(db::Database)
    for name in keys(db.loaders)
        validate_loader(db, name)
    end
    return nothing
end

function register_datasets(db::Database, datasets::Dict; kwargs...)
    L = get(datasets, "_LOADERS", get(datasets, "_loaders", nothing))
    if L isa Dict
        _warn_legacy_once()
        mods = haskey(L, "julia_modules") && L["julia_modules"] isa Vector ? String.(L["julia_modules"]) : String[]
        incs = haskey(L, "julia_includes") && L["julia_includes"] isa Vector ? String.(L["julia_includes"]) : String[]
        loader_dict = Dict{String,String}(String(k) => (v isa String ? v : repr(v)) for (k, v) in L if k != "julia_modules" && k != "julia_includes")
        register_loaders(db; loaders=loader_dict, julia_modules=mods, julia_includes=incs, persist=false)
    end
    # Structural `_*` top-level tables are never datasets. `_LOADERS`/`_loaders`
    # are consumed above; recognize `[_META].schema`; keep every other `_*`
    # table (`_META`, foreign `_LANG.<other>`, future `_FOO`) verbatim in extra.
    for (k, v) in pairs(datasets)
        ks = String(k)
        startswith(ks, "_") || continue
        (ks == "_LOADERS" || ks == "_loaders") && continue
        db.extra[ks] = v
    end
    storage = get(datasets, "_STORAGE", nothing)
    if storage isa AbstractDict
        db.storage_config = Dict{String,Any}(storage)  # invalidates the frozen config
    end
    meta = get(datasets, "_META", nothing)
    if meta isa AbstractDict && haskey(meta, "schema") && meta["schema"] isa Integer
        db.schema = Int(meta["schema"])
    end
    # Parse own top-level `[_LANG.julia.loaders]`; keep foreign `_LANG.<other>`.
    _parse_database_lang!(db)
    _ensure_project_root_on_load_path(db)
    names = [k for k in keys(datasets) if !startswith(String(k), "_")]
    for (i, name) in enumerate(names)
        info_ = datasets[name]
        info = Dict(Symbol(k) => v for (k, v) in (info_ isa Dict ? info_ : pairs(info_)))
        persist_on_last_iteration = i == length(names)
        register_dataset(db; name=name, persist=persist_on_last_iteration, info..., kwargs...)
    end
end

function register_datasets_toml(db::Database, datasets_toml ; kwargs...)
    config = TOML.parsefile(datasets_toml)
    register_datasets(db, config; kwargs...)
end

function register_datasets(db::Database, datasets_toml::String; kwargs...)
    ext = splitext(datasets_toml)[2]
    if ext == ".toml"
        register_datasets_toml(db, datasets_toml; kwargs...)
    else
        error("Only toml file type supported. Got: $ext")
    end
end

# ----- Database keyword constructor, get_default_database, get_project_root -----
"""
    Database(; datasets_toml="", datasets_folder="", persist=true, storage_config=nothing,
              skip_checksum=false, skip_checksum_folders=false, datasets=Dict(), kwargs...)

Construct a database from a manifest (`datasets_toml`, defaulting to the discoverable
manifest of the active project) or **in-memory** (`persist=false`: nothing is ever written
back to a manifest, and `db.datasets_toml == ""` even when a file was read). An in-memory
database keeps its state-file inventories under the storage roots it describes (see
[`dataset_state_root`](@ref) and the `db=` option of `@cached`), never under the caller's
project / cwd.

`storage_config` (optional `Dict`) sets the manifest-layer `[_STORAGE]` table directly —
the way to name an in-memory database's cache bundle, e.g.
`Database(datasets_folder=..., persist=false, storage_config=Dict("project" => "mylib"))`
puts produced artifacts under `…/projects/mylib/cached`. It overrides a `[_STORAGE]` table
read from `datasets_toml`. The configuration is frozen at construction
([`freeze_config!`](@ref)).
"""
function Database(; datasets_toml::String="", datasets_folder::String="",
    persist::Bool=true, skip_checksum::Bool=false, skip_checksum_folders::Bool=false,
    datasets::Dict{String,<:DatasetEntry}=Dict{String,DatasetEntry}(),
    storage_config::Union{Nothing,AbstractDict}=nothing, kwargs...)
    # A defaulted (empty) `datasets_folder` is left empty so the path model
    # resolves the `data` store via `Storage` (platformdirs). An explicit value
    # acts as the `data`-store root override (back-compat).
    if (datasets_toml == "" && persist)
        datasets_toml = get_default_toml()
    end
    toml_path = persist && datasets_toml != "" ? abspath(datasets_toml) : ""
    db = Database(
        datasets,
        toml_path,
        datasets_folder,
        skip_checksum,
        skip_checksum_folders,
        Dict{String,String}(),
        String[],
        String[],
        Dict{String,Function}(),
        nothing,
    )
    if isfile(datasets_toml)
        register_datasets(db, datasets_toml; kwargs...)
    end
    # An explicit storage_config is the manifest layer (it wins over a `[_STORAGE]` table
    # read from the file above); set before the freeze so the snapshot carries it.
    storage_config === nothing ||
        (db.storage_config = Dict{String,Any}(String(k) => v for (k, v) in storage_config))
    freeze_config!(db)
    return db
end

function Database(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

function get_project_root(db::Database)::String
    return project_root_from_paths(db.datasets_toml, Base.current_project())
end

function get_default_database()
    db = Database()
    if db.datasets_toml != ""
        info("""Using database: $(length(db.datasets_toml) > 60 ? "..." : "")$(db.datasets_toml[max(end-60, 1):end])""")
    else
        error("Please activate a julia environment or pass a Database instance explicity.")
    end
    return db
end

function read_dataset(datasets_toml::String, datasets_folder::String=""; kwargs...)
    return Database(; datasets_toml=datasets_toml, datasets_folder=datasets_folder, kwargs...)
end

function add(db::Database, uri::String ; skip_download::Bool=false, kwargs...)
    (name, entry) = register_dataset(db, uri; kwargs...)
    if ! skip_download
        parentmodule(@__MODULE__).PipeLines.download_dataset(db, entry)
    end
    return (name => entry)
end

# ----- Convenience methods (default database) -----
register_dataset(uri::String; kwargs...) = register_dataset(get_default_database(), uri; kwargs...)
register_dataset(db::Nothing, uri::String; kwargs...) = register_dataset(uri; kwargs...)
delete_dataset(name::String; kwargs...) = delete_dataset(get_default_database(), name; kwargs...)
add(uri::String=""; kwargs...) = add(get_default_database(), uri; kwargs...)
get_dataset_path(name::String; kwargs...) = get_dataset_path(get_default_database(), name; kwargs...)

function migrate(path::String)
    isfile(path) || error("File not found: $path")
    config = TOML.parsefile(path)

    meta = get(config, "_META", nothing)
    schema = (meta isa AbstractDict && haskey(meta, "schema")) ? meta["schema"] : nothing
    if schema isa Integer && schema >= 1
        info("migrate: $path is already schema v$schema, nothing to do")
        return
    end

    # Migrate [_LOADERS] format-loader entries that are refs into [_LANG.julia.loaders]
    for lkey in ("_LOADERS", "_loaders")
        L = get(config, lkey, nothing)
        L isa AbstractDict || continue
        migrated = Dict{String,String}()
        for (k, v) in L
            ks = String(k)
            ks in ("julia_modules", "julia_includes") && continue
            if v isa String && !isempty(v)
                if _is_ref(v)
                    migrated[ks] = v
                else
                    warn("migrate: [_LOADERS][$ks] looks like inline code; preserved verbatim")
                end
            end
        end
        if !isempty(migrated)
            lang = get(config, "_LANG", Dict{String,Any}())
            lang = lang isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in lang) : Dict{String,Any}()
            jul = get(lang, "julia", Dict{String,Any}())
            jul = jul isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in jul) : Dict{String,Any}()
            ldr = get(jul, "loaders", Dict{String,Any}())
            ldr = ldr isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in ldr) : Dict{String,Any}()
            for (fmt, ref) in migrated
                ldr[fmt] = ref
            end
            jul["loaders"] = ldr
            lang["julia"] = jul
            config["_LANG"] = lang
            remaining = Dict{String,Any}(String(k) => v for (k, v) in L
                                         if !(String(k) in keys(migrated)))
            if isempty(remaining)
                delete!(config, lkey)
            else
                config[lkey] = remaining
            end
        end
        break
    end

    # Migrate per-dataset julia= and loader= refs into [<ds>._LANG.julia]
    for dsname in collect(keys(config))
        startswith(String(dsname), "_") && continue
        dsval = config[dsname]
        dsval isa AbstractDict || continue
        ds = Dict{String,Any}(String(k) => v for (k, v) in dsval)
        lang_julia = Dict{String,Any}()
        for (field, target) in (("julia", "fetcher"), ("loader", "loader"))
            v = get(ds, field, nothing)
            if v isa String && !isempty(v)
                if _is_ref(v)
                    lang_julia[target] = v
                    delete!(ds, field)
                else
                    warn("migrate: [$dsname].$field looks like inline code; preserved verbatim")
                end
            end
        end
        if !isempty(lang_julia)
            lang = get(ds, "_LANG", Dict{String,Any}())
            lang = lang isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in lang) : Dict{String,Any}()
            jul = get(lang, "julia", Dict{String,Any}())
            jul = jul isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in jul) : Dict{String,Any}()
            for (k, v) in lang_julia
                jul[k] = v
            end
            lang["julia"] = jul
            ds["_LANG"] = lang
            config[String(dsname)] = ds
        end

        # Migrate per-dataset shell= into [<ds>._LANG.shell].fetcher
        shell_v = get(ds, "shell", nothing)
        if shell_v isa String && !isempty(shell_v)
            lang = get(ds, "_LANG", Dict{String,Any}())
            lang = lang isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in lang) : Dict{String,Any}()
            sh = get(lang, "shell", Dict{String,Any}())
            sh = sh isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in sh) : Dict{String,Any}()
            sh["fetcher"] = shell_v
            lang["shell"] = sh
            ds["_LANG"] = lang
            delete!(ds, "shell")
            config[String(dsname)] = ds
        end
    end

    # Set _META.schema = 1
    meta_dict = get(config, "_META", Dict{String,Any}())
    meta_dict = meta_dict isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in meta_dict) : Dict{String,Any}()
    meta_dict["schema"] = 1
    config["_META"] = meta_dict

    open(path, "w") do io
        TOML.print(io, config; sorted=true, by=_toml_sort_key)
    end
    info("migrate: wrote v1 manifest to $path")
    return nothing
end

end # module Databases

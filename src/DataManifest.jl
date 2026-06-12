module DataManifest

using TOML
using URIs
using Logging
using SHA
import Downloads
import Base: write

# Compat: Julia 1.10's Cmd(exec) only accepts Vector{String}; Julia 1.11+ accepts Vector{<:AbstractString}
if VERSION < v"1.11"
    Base.Cmd(exec::Vector{<:AbstractString}) = Base.Cmd(String.(exec))
end

include("Config.jl")
include("Storage.jl")
include("Databases.jl")
include("DefaultLoaders.jl")
include("PipeLines.jl")
include("Cache.jl")

# Extend Base.write for Database (Databases.write is the implementation)
write(db::Databases.Database, path::String; kwargs...) = Databases.write(db, path; kwargs...)

# Backward compatibility: Loaders was a submodule; default loaders now live in PipeLines
const Loaders = PipeLines

# Optional default loaders by format (csv, parquet, nc, dimstack, md, txt, json, yaml, toml)
export DefaultLoaders
using .DefaultLoaders: default_loader

# Re-export public API from Databases and PipeLines
using .Databases: Database, DatasetEntry,
    set_datasets_folder, set_datasets, get_datasets_folder, get_datasets,
    repr_short, string_short, get_dataset_path,
    register_dataset, register_datasets, register_loaders, validate_loader, validate_loaders,
    search_datasets, search_dataset,
    repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys,
    verify_checksum, read_dataset, delete_dataset, add, migrate, freeze_config!
using .PipeLines: download_dataset, download_datasets, load_dataset, get_project_root

const add_dataset = add

export Databases, PipeLines, Loaders, Storage, Cache
# Produce-or-load (`@cached`) companion layer — spec-v4.1 `cache-produce`.
using .Cache: @cached, param_hash, cache_key,
    CachedIndex, read_index, read_index_or_empty, register!, index_keys, reachable_keys,
    has_instance, ref_of, instance_path_of, remove_instance!, recipe_records,
    register_dataset!, has_dataset, dataset_path_of, dataset_sha256_of, set_dataset_path!,
    remove_dataset!, dataset_records, write_index, locate_state, STATE_FILE_NAME,
    CacheObject, enumerate_artifacts, delete_object, move_object,
    last_access, iso_from_mtime
export @cached, param_hash, cache_key
export CachedIndex, read_index, read_index_or_empty, register!, index_keys, reachable_keys
export has_instance, ref_of, instance_path_of, recipe_records, write_index, locate_state
export register_dataset!, has_dataset, dataset_path_of, dataset_sha256_of, dataset_records
export CacheObject, enumerate_artifacts, delete_object, move_object
export last_access, iso_from_mtime
export inspect_store

"""
    inspect_store(db::Database; cache_root="", cached_toml="") -> Vector{Cache.CacheObject}

The `inspect` composition root (spec-v4.1 store maintenance): enumerate produced artifacts
(the cache layer) and present fetched datasets (the fetch layer) as one list of
maintenance objects, resolving `referenced` — the one place that bridges both layers.

A produced artifact is `referenced` iff its `(cachetype, version, hash)` identity is rooted by
the project's state file (`.datamanifest/state.toml`, or a legacy `.datamanifest-state.toml` /
`cached.toml`); a
present fetched dataset is referenced by its manifest entry. For an **in-memory** database
(`datasets_toml == ""`) the produced inventory lives under the resolved datacache root itself
(`<datacache_dir>/.datamanifest/state.toml`), and that is where it is read from — so
maintenance over a library's cache bundle works without a project. `cache_root` / `cached_toml`
override the resolved `datacache_dir` and the state-file path (both default from `db`). Pass
the result through your own filter (`kind`, `referenced == false`, `last_access` age, …) and
act with [`delete_object`] / [`move_object`].
"""
function inspect_store(db::Databases.Database; cache_root::AbstractString="",
                       cached_toml::AbstractString="")::Vector{Cache.CacheObject}
    project_root = PipeLines.get_project_root(db)
    sc = Databases.storage_layers(db)
    objects = Cache.CacheObject[]

    # Produced artifacts under the manifest's `datacache_dir` (spec-v4), tagged referenced via
    # the state file on the `(cachetype, version, hash)` reachability key. An in-memory
    # database keeps that inventory under the resolved datacache root itself
    # (`<datacache_dir>/.datamanifest/state.toml`), not under a project / the cwd.
    default_croot = Storage.datacache_dir(; project_root=project_root, storage_config=sc)
    croot = isempty(cache_root) ? default_croot : String(cache_root)
    base = db.datasets_toml != "" ? dirname(db.datasets_toml) : default_croot
    idx_path = isempty(cached_toml) ? Cache.locate_state(base) : String(cached_toml)
    referenced_keys = Set{NTuple{3,String}}()
    if isfile(idx_path)
        try
            referenced_keys = Cache.reachable_keys(Cache.read_index(idx_path))
        catch
        end
    end
    for obj in Cache.enumerate_artifacts(croot)
        obj.referenced = (obj.cachetype, obj.version, obj.hash) in referenced_keys
        push!(objects, obj)
    end

    # Present fetched datasets (always referenced — they are manifest entries).
    for (name, entry) in db.datasets
        path = try
            Databases.resolve_existing_path(db, entry)
        catch
            continue
        end
        (isfile(path) || isdir(path)) || continue
        sz = isfile(path) ? (try; filesize(path); catch; 0; end) : Cache._dir_size(path)
        push!(objects, Cache.CacheObject(
            kind="datasets", location=abspath(path), key=name,
            format=entry.format, size=sz,
            created=Cache.iso_from_mtime(path), last_access=Cache.last_access(path),
            referenced=true))
    end
    return objects
end
export Database, DatasetEntry
export set_datasets_folder, set_datasets, get_datasets_folder, get_datasets
export repr_short, string_short
export get_dataset_path
export register_dataset, register_datasets, register_loaders, validate_loader, validate_loaders
export search_datasets, search_dataset
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export verify_checksum
export read_dataset, delete_dataset, freeze_config!
export add, add_dataset
export download_dataset, download_datasets
export load_dataset
export get_project_root
export default_loader
export migrate

end # module DataManifest

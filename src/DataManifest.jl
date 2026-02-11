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
include("DataBase.jl")
include("DefaultLoaders.jl")
include("PipeLines.jl")

# Extend Base.write for Database (DataBase.write is the implementation)
write(db::DataBase.Database, path::String; kwargs...) = DataBase.write(db, path; kwargs...)

# Backward compatibility: Loaders was a submodule; default loaders now live in PipeLines
const Loaders = PipeLines

# Optional default loaders by format (csv, parquet, nc, dimstack, md, txt, json, yaml, toml)
export DefaultLoaders
using .DefaultLoaders: default_loader

# Re-export public API from DataBase and PipeLines
using .DataBase: Database, DatasetEntry,
    set_datasets_folder, set_datasets, get_datasets_folder, get_datasets,
    repr_short, string_short, get_dataset_path,
    register_dataset, register_datasets, register_loaders,
    search_datasets, search_dataset,
    repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys,
    verify_checksum, read_dataset, delete_dataset, add
using .PipeLines: download_dataset, download_datasets, load_dataset, get_project_root

const add_dataset = add

export DataBase, PipeLines, Loaders
export Database, DatasetEntry
export set_datasets_folder, set_datasets, get_datasets_folder, get_datasets
export repr_short, string_short
export get_dataset_path
export register_dataset, register_datasets, register_loaders
export search_datasets, search_dataset
export repr_datasets, print_dataset_keys, list_dataset_keys, list_alternative_keys
export verify_checksum
export read_dataset, delete_dataset
export add, add_dataset
export download_dataset, download_datasets
export load_dataset
export get_project_root
export default_loader

end # module DataManifest

# Optional default loaders by format. No compulsory dependency: each loader requires its
# package at use-time and errors with an "add Package" message if missing.
# Used by PipeLines when no loader is set on the dataset and format is non-empty.
module DefaultLoaders

using TOML  # already a dependency of DataManifest

# Directory containing this file (src/); used to find NetCDFDimStack.jl when pathof(DefaultLoaders) is nothing (e.g. in CI).
const _SRC_DIR = @__DIR__

# Standard registry UUIDs for optional loader packages (so we can require by full PkgId
# and find them in the user's project or depot regardless of DataManifest's own deps).
const _LOADER_PKG_UUIDS = Dict{String,Base.UUID}(
    "CodecZlib" => Base.UUID("944b1d66-785c-5afd-91f1-9de20f533193"),
    "CSV" => Base.UUID("336ed68f-0bac-5ca0-87d4-7b16caf5d00b"),
    "DataFrames" => Base.UUID("a93c6f00-e57d-5684-b7b6-d8193f3e46c0"),
    "DimensionalData" => Base.UUID("0703355e-b756-11e9-17c0-8b28908087d0"),
    "JSON" => Base.UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6"),
    "NCDatasets" => Base.UUID("85f8d34a-cbdd-5861-8df4-14fed0d494ab"),
    "OrderedCollections" => Base.UUID("bac558e1-5e72-5ebc-8fee-abe8a469f55d"),
    "Parquet" => Base.UUID("626c502c-15b0-58ad-a749-f091afb673ae"),
    "Tar" => Base.UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"),
    "YAML" => Base.UUID("ddb6d928-2868-570f-bddf-ab3f9cf99eb6"),
    "ZipFile" => Base.UUID("a5390f91-8eb1-5f08-bee0-b1d1ffed6cea"),
)

# Try to get a module by name: already loaded, or require by name, or require by full PkgId.
# Does not depend on DataManifest's Project.toml; finds packages in the active project or depot.
function _optional_module(name::String)
    for (id, mod) in Base.loaded_modules
        id.name == Symbol(name) && return mod
    end
    try
        return Base.require(Base.PkgId(name))
    catch
        nothing
    end
    uuid = get(_LOADER_PKG_UUIDS, name, nothing)
    if uuid !== nothing
        try
            return Base.require(Base.PkgId(uuid, name))
        catch
            return nothing
        end
    end
    return nothing
end

"""
    default_loader(format::AbstractString) -> Function

Return a loader function `path -> value` for the given format. Formats use optional
packages; if the package is not installed, the loader errors with a message to add it.
Supported formats: csv, parquet, nc, dimstack, md, txt, json, yaml, yml, toml, zip, tar, tar.gz.

For **zip**, **tar**, **tar.gz**, the loader extracts the archive to a temporary directory and returns that directory path (string). Useful when `extract=false`: the dataset path is the archive file and the loader yields the extracted tree.

For **dimstack**, the loader returns a `DimStack` of all data variables (each layer is a
`DimArray` with variable attributes in `metadata`). Implemented by loading an experimental
module at runtime that uses `exclude_coords=true` (coordinate variables are not stacked).
"""
function default_loader(format::AbstractString)
    f = lowercase(strip(format))
    if isempty(f)
        error("No loader provided and dataset format is empty. Pass a loader function, e.g. loader = path -> read(path, String).")
    end
    if f == "csv"
        return _csv_loader
    elseif f == "parquet"
        return _parquet_loader
    elseif f == "nc"
        return _nc_loader
    elseif f == "dimstack"
        return _dimstack_loader
    elseif f in ("md", "txt")
        return _text_io_loader
    elseif f == "json"
        return _json_loader
    elseif f in ("yaml", "yml")
        return _yaml_loader
    elseif f == "toml"
        return _toml_loader
    elseif f == "zip"
        return _zip_loader
    elseif f == "tar"
        return _tar_loader
    elseif f == "tar.gz"
        return _tar_gz_loader
    else
        error("No default loader for format \"$format\". Pass a loader function or register a named loader in [_loaders].")
    end
end

function _csv_loader(path)
    csv = _optional_module("CSV")
    df = _optional_module("DataFrames")
    if csv === nothing || df === nothing
        error("For CSV default loader, add CSV and DataFrames: using Pkg; Pkg.add([\"CSV\", \"DataFrames\"])")
    end
    return Base.invokelatest(csv.read, path, df.DataFrame; comment="#")
end

function _parquet_loader(path)
    parquet = _optional_module("Parquet")
    df = _optional_module("DataFrames")
    if parquet === nothing || df === nothing
        error("For Parquet default loader, add Parquet and DataFrames: using Pkg; Pkg.add([\"Parquet\", \"DataFrames\"])")
    end
    return df.DataFrame(Base.invokelatest(parquet.read_parquet, path))
end

function _nc_loader(path)
    nc = _optional_module("NCDatasets")
    nc === nothing && error("For NetCDF default loader, add NCDatasets: using Pkg; Pkg.add(\"NCDatasets\")")
    return Base.invokelatest(nc.NCDataset, path)
end

const _netcdf_dimstack_module = Ref{Union{Nothing,Module}}(nothing)

function _dimstack_loader(path)
    nc = _optional_module("NCDatasets")
    dim = _optional_module("DimensionalData")
    ord = _optional_module("OrderedCollections")
    if nc === nothing || dim === nothing || ord === nothing
        error("For dimstack default loader, add NCDatasets, DimensionalData and OrderedCollections: using Pkg; Pkg.add([\"NCDatasets\", \"DimensionalData\", \"OrderedCollections\"])")
    end
    path_nc = path
    # path_nc = occursin('#', path) ? String(split(path, '#'; limit=2)[1]) : path
    # Load experimental module in Main so 'using' resolves against the active project, not DataManifest's deps
    if _netcdf_dimstack_module[] === nothing
        mod_path = joinpath(_SRC_DIR, "NetCDFDimStack.jl")
        _netcdf_dimstack_module[] = Main.include(mod_path)
    end
    mod = _netcdf_dimstack_module[]
    return Base.invokelatest() do
        mod.load_netcdf_as_dimstack(path_nc)
    end
end

"""Return an open IO stream for the path. Caller should use in a do-block or close the stream."""
function _text_io_loader(path)
    return open(path)
end

function _json_loader(path)
    json = _optional_module("JSON")
    json === nothing && error("For JSON default loader, add JSON: using Pkg; Pkg.add(\"JSON\")")
    return Base.invokelatest(json.parsefile, path)
end

function _yaml_loader(path)
    yaml = _optional_module("YAML")
    yaml === nothing && error("For YAML default loader, add YAML: using Pkg; Pkg.add(\"YAML\")")
    return Base.invokelatest(yaml.load_file, path)
end

function _toml_loader(path)
    return TOML.parsefile(path)
end

function _zip_loader(path)
    zf = _optional_module("ZipFile")
    zf === nothing && error("For ZIP default loader, add ZipFile: using Pkg; Pkg.add(\"ZipFile\")")
    dir = mktempdir(prefix="DataManifest_zip_"; cleanup=true)
    r = zf.Reader(path)
    try
        dir_abs = abspath(dir)
        for f in r.files
            outpath = abspath(joinpath(dir, f.name))
            (outpath == dir_abs || startswith(outpath, dir_abs * "/")) || continue
            if endswith(f.name, "/")  # directory entry
                mkpath(outpath)
            else
                mkpath(dirname(outpath))
                write(outpath, read(f))
            end
        end
        return dir
    finally
        close(r)
    end
end

function _tar_loader(path)
    tar = _optional_module("Tar")
    tar === nothing && error("For tar default loader, add Tar: using Pkg; Pkg.add(\"Tar\")")
    dir = mktempdir(prefix="DataManifest_tar_"; cleanup=true)
    tar.extract(path, dir)
    return dir
end

function _tar_gz_loader(path)
    tar = _optional_module("Tar")
    codecz = _optional_module("CodecZlib")
    if tar === nothing || codecz === nothing
        error("For tar.gz default loader, add Tar and CodecZlib: using Pkg; Pkg.add([\"Tar\", \"CodecZlib\"])")
    end
    dir = mktempdir(prefix="DataManifest_tar_gz_"; cleanup=true)
    open(path) do io
        tar.extract(codecz.GzipDecompressorStream(io), dir)
    end
    return dir
end

end # module DefaultLoaders

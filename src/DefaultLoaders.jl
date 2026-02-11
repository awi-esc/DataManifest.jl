# Optional default loaders by format. No compulsory dependency: each loader requires its
# package at use-time and errors with an "add Package" message if missing.
# Used by PipeLines when no loader is set on the dataset and format is non-empty.
module DefaultLoaders

using TOML  # already a dependency of DataManifest

"""
    default_loader(format::AbstractString) -> Function

Return a loader function `path -> value` for the given format. Formats use optional
packages; if the package is not installed, the loader errors with a message to add it.
Supported formats: csv, parquet, nc, dimstack, md, txt, json, yaml, yml, toml, zip, tar, tar.gz.

For **zip**, **tar**, **tar.gz**, the loader extracts the archive to a temporary directory and returns that directory path (string). Useful when `extract=false`: the dataset path is the archive file and the loader yields the extracted tree.

For **dimstack**, the loader returns a `DimStack` of all variables (each layer is a
`DimArray` with variable attributes in `metadata`). If the file has global (file-level)
NetCDF attributes, they are stored in a dummy layer `_global` as `metadata` (e.g.
`stack._global.metadata`).
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
    try
        csv = Base.require(Base.PkgId("CSV"))
        df = Base.require(Base.PkgId("DataFrames"))
        return csv.read(path, df.DataFrame)
    catch
        error("For CSV default loader, add CSV and DataFrames: using Pkg; Pkg.add([\"CSV\", \"DataFrames\"])")
    end
end

function _parquet_loader(path)
    try
        parquet = Base.require(Base.PkgId("Parquet"))
        df = Base.require(Base.PkgId("DataFrames"))
        return df.DataFrame(parquet.read_parquet(path))
    catch
        error("For Parquet default loader, add Parquet and DataFrames: using Pkg; Pkg.add([\"Parquet\", \"DataFrames\"])")
    end
end

function _nc_loader(path)
    try
        nc = Base.require(Base.PkgId("NCDatasets"))
        return nc.NCDataset(path)
    catch
        error("For NetCDF default loader, add NCDatasets: using Pkg; Pkg.add(\"NCDatasets\")")
    end
end

function _dimstack_loader(path)
    try
        nc = Base.require(Base.PkgId("NCDatasets"))
        dim = Base.require(Base.PkgId("DimensionalData"))
        ds = nc.NCDataset(path)
        try
            global_attrib = Dict{String,Any}(pairs(ds.attrib))
            layers = []
            for name in keys(ds)
                v = ds[name]
                A = collect(v[:])
                dimnames = nc.dimnames(v)
                dim_lengths = (length(ds.dim[d]) for d in dimnames)
                dim_objs = [dim.Dim(Symbol(d))(1:n) for (d, n) in zip(dimnames, dim_lengths)]
                var_attrib = Dict{String,Any}(pairs(v.attrib))
                push!(layers, Symbol(name) => dim.DimArray(A, dim_objs...; metadata=var_attrib))
            end
            if !isempty(global_attrib)
                push!(layers, :_global => dim.DimArray([0], dim.Dim{:global}(1:1); metadata=global_attrib))
            end
            return dim.DimStack((; layers...))
        finally
            close(ds)
        end
    catch e
        if e isa KeyError
            rethrow(e)
        end
        error("For dimstack default loader, add NCDatasets and DimensionalData: using Pkg; Pkg.add([\"NCDatasets\", \"DimensionalData\"])")
    end
end

"""Return an open IO stream for the path. Caller should use in a do-block or close the stream."""
function _text_io_loader(path)
    return open(path)
end

function _json_loader(path)
    try
        json = Base.require(Base.PkgId("JSON"))
        return json.parsefile(path)
    catch
        error("For JSON default loader, add JSON: using Pkg; Pkg.add(\"JSON\")")
    end
end

function _yaml_loader(path)
    try
        yaml = Base.require(Base.PkgId("YAML"))
        return yaml.load_file(path)
    catch
        error("For YAML default loader, add YAML: using Pkg; Pkg.add(\"YAML\")")
    end
end

function _toml_loader(path)
    return TOML.parsefile(path)
end

function _zip_loader(path)
    try
        zf = Base.require(Base.PkgId("ZipFile"))
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
        finally
            close(r)
        end
        return dir
    catch
        error("For ZIP default loader, add ZipFile: using Pkg; Pkg.add(\"ZipFile\")")
    end
end

function _tar_loader(path)
    try
        tar = Base.require(Base.PkgId("Tar"))
        dir = mktempdir(prefix="DataManifest_tar_"; cleanup=true)
        tar.extract(path, dir)
        return dir
    catch
        error("For tar default loader, add Tar: using Pkg; Pkg.add(\"Tar\")")
    end
end

function _tar_gz_loader(path)
    try
        tar = Base.require(Base.PkgId("Tar"))
        codecz = Base.require(Base.PkgId("CodecZlib"))
        dir = mktempdir(prefix="DataManifest_tar_gz_"; cleanup=true)
        open(path) do io
            tar.extract(codecz.GzipDecompressorStream(io), dir)
        end
        return dir
    catch
        error("For tar.gz default loader, add Tar and CodecZlib: using Pkg; Pkg.add([\"Tar\", \"CodecZlib\"])")
    end
end

end # module DefaultLoaders

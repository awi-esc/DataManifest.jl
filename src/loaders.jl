# Default loaders by format. Grows over time; optional deps (e.g. CSV) used when available.

"""
    default_loader(format::AbstractString) -> Function

Return a loader function `path -> value` for the given format, when no loader is passed to `load_dataset`.
Supported formats may use optional dependencies (e.g. CSV for \"csv\"); if unavailable, an error suggests
adding the dependency or passing a custom loader.
"""
function default_loader(format::AbstractString)
    f = lowercase(strip(format))
    if isempty(f)
        error("No loader provided and dataset format is empty. Pass a loader function, e.g. loader = path -> read(path, String).")
    end
    if f == "csv"
        return _csv_loader
    end
    error("No default loader for format \"$format\". Pass a loader function, e.g. loader = path -> CSV.read(path, DataFrame).")
end

function _csv_loader(path)
    try
        csv = Base.require(Base.PkgId("CSV"))
        return csv.read(path)
    catch
        error("No loader provided. For CSV format, add CSV (using Pkg; Pkg.add(\"CSV\")) and load it (using CSV), or pass loader = path -> CSV.read(path, DataFrame).")
    end
end

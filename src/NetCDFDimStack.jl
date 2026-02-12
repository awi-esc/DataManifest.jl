# Experimental module: load NetCDF as DimStack. Loaded at runtime when dimstack loader is used.
# Requires NCDatasets, DimensionalData, OrderedCollections to be already loaded.

module NetCDFDimStack

using NCDatasets: Dataset, dimnames
using DimensionalData: DimArray, DimStack, Metadata, NoMetadata
using OrderedCollections: OrderedDict

"""
    load_netcdf_as_dimstack(filepath; variables=nothing, exclude_coords=true)

Load a NetCDF file as a `DimStack` using NCDatasets.

# Arguments
- `filepath`: Path to the NetCDF file.
- `variables`: Optional vector of variable names (String or Symbol) to load.
  If `nothing`, loads all data variables (excluding coordinate variables when `exclude_coords=true`).
- `exclude_coords`: If `true` (default), exclude coordinate variables (variables whose name equals
  a dimension name, e.g. "lon", "lat", "time").

# Returns
- `DimStack`: Named tuple of `DimArray`s, one per variable. Each `DimArray` has coordinates
  inferred from dimension names (using matching variables when they exist, or 1:n otherwise).

# Example
```julia
ds = load_netcdf_as_dimstack("myfile.nc")
ds[:temperature]  # access a variable
```
"""
function load_netcdf_as_dimstack(filepath; variables=nothing, exclude_coords::Bool=true)
    Dataset(filepath) do ds
        varnames = if variables !== nothing
            [String(v) for v in variables]
        else
            names = [String(name) for name in keys(ds)]
            if exclude_coords
                dim_names = Set(String(d) for d in dimnames(ds))
                [n for n in names if !(n in dim_names)]
            else
                names
            end
        end
        dimarrays = OrderedDict{Symbol,DimArray}()
        for varname in varnames
            dimarrays[Symbol(varname)] = _ncvar_to_dimarray(ds, varname)
        end
        return DimStack(NamedTuple(dimarrays))
    end
end

"""Convert NetCDF variable attributes to DimensionalData Metadata, or NoMetadata if empty/fails."""
function _attrib_to_metadata(attrib)
    isempty(attrib) && return NoMetadata()
    try
        dict = Dict(Symbol(k) => v for (k, v) in pairs(attrib))
        return Metadata(dict)
    catch
        return NoMetadata()
    end
end

"""Convert a single NetCDF variable to DimArray with coordinates from dimension names."""
function _ncvar_to_dimarray(ds, varname)
    var = ds[Symbol(varname)]
    dim_names = dimnames(var)
    coords = NamedTuple(
        Symbol(dimname) => (
            dimname in keys(ds) ? ds[dimname][:] : collect(1:size(var, i))
        )
        for (i, dimname) in enumerate(dim_names)
    )
    meta = _attrib_to_metadata(var.attrib)
    return DimArray(Array(var), coords; metadata=meta)
end

end # module NetCDFDimStack

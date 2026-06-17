# Formats: the single shared serialization registry — `format → optional save + load`.
#
# DataManifest names a serialization with the word `format` on both sides of the library: a
# *fetched dataset* needs only the read half (`format → loader`, resolved via DefaultLoaders +
# named loaders), while a *produced cache* artifact (`@cached`) needs read + write
# (`format → (save, load)`). Both used to keep their own registry; this module is the one place
# they share. A `format` may register a full `(save, load)` pair (a cache codec, also loadable
# as a dataset) or a load-only entry (`save === nothing`: a read-only format — loadable as a
# dataset, but a `@cached` produce with it errors unless a `saver=` is supplied).
#
# The override vocabulary lives ABOVE this registry and is not stored here: the db-context
# loader resolution (named loaders, `[_LANG.julia.loaders]`, explicit `loader=`) and the
# per-call `loader=`/`saver=` of `@cached` beat the registry for a given call. This module only
# holds the format defaults.
#
# Included after Config (it has no DataManifest dependency); both DefaultLoaders and Cache use it.
module Formats

export register_format!, registered_loader, registered_saver, has_format

# `format → (save, load)`, where `save` may be `nothing` for a read-only format. `load` may be
# `nothing` for a write-only codec (uncommon, but symmetric — a load-only entry is the usual
# read-only case).
const _FORMATS = Dict{String,NamedTuple{(:save, :load),Tuple{Union{Function,Nothing},Union{Function,Nothing}}}}()

"""
    register_format!(format, save, load)
    register_format!(format; load, save=nothing)

Register the serialization named `format` in the shared format registry — the single home for
both the produced-cache `(save, load)` codec and the dataset `load` (reader). `save(data, path)`
writes the artifact and `load(path)` reads it back.

Two call forms:

- `register_format!(format, save, load)` — the full `(save, load)` pair (a cache codec). Such a
  format is usable both as a `@cached` codec (read + write) and, automatically, as a dataset
  loader (its `load` is reachable from [`DataManifest.default_loader`](@ref)).
- `register_format!(format; load, save=nothing)` — the keyword form. With `save=nothing` (the
  default) the format is **read-only**: loadable as a dataset, but a `@cached` produce selecting
  it errors unless the call passes an explicit `saver=`. Pass `save=` to make it a full codec.

`format` is the **serialization name** (the registry key), not necessarily the on-disk file
suffix: a `@cached` site selects a codec with `format=` and names the file with a separate
`ext=` (defaulting to `format`). So a custom codec can write a standard, tool-recognisable
suffix — e.g. `register_format!("nceof", write, read)` decorated with `format="nceof" ext="nc"`
produces a `data.nc` loaded by the EOF reader.
"""
function register_format!(format::AbstractString, save::Function, load::Function)
    _FORMATS[String(format)] = (save=save, load=load)
    return nothing
end

function register_format!(format::AbstractString;
                          load::Union{Function,Nothing}=nothing,
                          save::Union{Function,Nothing}=nothing)
    (load === nothing && save === nothing) &&
        error("register_format!(\"$(format)\"; …): pass at least one of `load=` or `save=`.")
    _FORMATS[String(format)] = (save=save, load=load)
    return nothing
end

"""
    has_format(format) -> Bool

Whether `format` is registered (with a `save`, a `load`, or both).
"""
has_format(format::AbstractString)::Bool = haskey(_FORMATS, String(format))

"""
    registered_loader(format) -> Function or nothing

The registered reader (`path -> value`) for `format`, or `nothing` when the format is
unregistered or registered write-only.
"""
function registered_loader(format::AbstractString)
    e = get(_FORMATS, String(format), nothing)
    e === nothing ? nothing : e.load
end

"""
    registered_saver(format) -> Function or nothing

The registered writer (`(data, path) -> nothing`) for `format`, or `nothing` when the format is
unregistered or registered read-only.
"""
function registered_saver(format::AbstractString)
    e = get(_FORMATS, String(format), nothing)
    e === nothing ? nothing : e.save
end

end # module Formats

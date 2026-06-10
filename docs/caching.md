# Produce-or-load caching (`@cached`)

The [README](../README.md#produce-or-load-caching-cached) shows the short
version; this page is the full behaviour of the `@cached` layer.

Beyond *fetching* declared datasets, DataManifest can *produce-or-load* — cache the result
of a project function on disk, keyed by its parameters:

```julia
using DataManifest

@cached key=(a -> (; a.grid, a.skip_models)) function load_anomaly(;
        grid::String = "5x5",
        skip_models::Vector{String} = ["CESM.*", "FGOALS.*"],
        _verbose::Bool = false)          # `_`-prefixed = runtime knob, excluded from the hash
    # … expensive computation …
    return result
end

load_anomaly(; grid="5x5")               # computes once, then loads from disk on repeat calls
load_anomaly(; grid="5x5", cached=false) # escape hatch: run the body, no disk I/O
```

## The cache key

The cache key is the SHA-256 of the **canonical JSON** of the hash-affecting keyword
parameters (cross-tool reproducible). Produced datasets are **keyword-only**; hash inputs are
strings/integers/booleans/**finite floats**/arrays/objects of those — finite floats use the
normative Python `json.dumps` form (`1.0`→`1.0`), while `NaN`/`±Inf` and nulls raise.

## Artifacts on disk

Each artifact is self-describing — `config.toml` (the re-hashable key table) and
`metadata.toml` (provenance) sit alongside it under **`datacache_dir`** at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/` (default the per-project
`$user_cache_dir/datamanifest/projects/$project/cached`). `jls` (stdlib
`Serialization`) is the built-in zero-dependency format; register others (`nc`, `jld2`, …)
with `DataManifest.Cache.register_format!`. (The spec RECOMMENDS `jld2` as the Julia
per-language default; shipping `jls` as the built-in self-saver is a documented,
spec-permitted deviation.)

## Cache identity (`cachetype`)

**`cachetype` is optional**: when omitted it defaults to the producing function's canonical
*importable* name — `Module.func` — so it coincides with the recipe `ref`. Pass an explicit
`cachetype=` to override it, and `version=` to deliberately bust the cache. A function with
**no stable importable identity** (script / REPL / `eval` / notebook) must be given an
explicit `cachetype`. (The macro lost its old `store=`/`scope=` options; `cache_dir=` — a
verbatim experiment folder that bypasses `datacache_dir` entirely — and `version=` remain.)

Where artifacts are recorded, how a moved or deleted state file recovers, and how
to inspect / prune the cache: see [storage.md](storage.md).

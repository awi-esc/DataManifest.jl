# Produce-or-load caching (`@cached`)

`@cached` wraps a function so that its result is computed once and saved to disk;
later calls with the same parameters load the saved result instead of recomputing
it. The saved result is called an **artifact**. This is separate from fetching
declared datasets: an artifact comes from running your own code, not from
downloading a URI, and it has no entry in `datasets.toml`. The
[walkthrough](doc.md) shows the short version;
this page describes the full behaviour.

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

The wrapped function must take keyword arguments only — positional arguments are
rejected, because the cache key is built from named parameters. The macro adds a
`cached::Bool=true` keyword to the function: pass `cached=false` to run the body
directly, with no disk reads or writes.

## Macro options

- `key` (required): a function that receives the call's keyword arguments as a
  NamedTuple (every declared keyword except `_`-prefixed runtime knobs) and
  returns the **key table** — the parameters that identify the result. Two calls
  whose key tables are equal share one artifact.
- `cachetype` (optional): the namespace artifacts are stored under. Defaults to
  the function's importable name, `Module.func`, so distinct functions never
  collide. A function with no stable importable name — defined in a script, the
  REPL, a notebook, or via `eval` — must be given an explicit `cachetype`.
- `version` (optional): a version string that becomes part of the artifact path.
  Bump it to deliberately invalidate the cache, e.g. after changing the
  function's code (the code itself is not hashed).
- `ext` (default `"jls"`) and `basename` (default `"data"`): the artifact's file
  format and file name.

## The cache key

Each key table maps to a **cache key** in two steps. First the table is
serialized to **canonical JSON** — a fully specified JSON encoding (RFC 8785)
with object keys sorted and no insignificant whitespace, so the same table
always yields the same bytes. The **parameter hash** is the SHA-256 of those
bytes. Because the byte form is pinned, other tools (such as the Python
implementation) compute the same hash, and caches are shared across languages.

Values in the key table may be strings, integers, booleans, finite floats, and
arrays/objects of those. Floats are written in the form Python's `json.dumps`
uses (`1.0` → `1.0`, `1e-5` → `1e-05`). `NaN`, `±Inf`, and nulls
(`nothing`/`missing`) raise an error, since they have no stable JSON form.

## Artifacts on disk

Each artifact is a self-describing directory at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/`, where `datacache_dir`
defaults to the per-project `$user_cache_dir/datamanifest/projects/$project/cached`
(see [storage.md](storage.md) for how it is configured). The directory contains:

- `<basename>.<ext>` — the artifact itself;
- `config.toml` — a **sidecar** (a small file stored next to the artifact)
  holding the key table and the recorded hash, so the hash can be recomputed and
  verified from disk alone;
- `metadata.toml` — a sidecar with provenance: creation time, tool, host, user,
  and git state;
- `.complete` — a marker that the write finished.

A directory only counts as a cache hit when its `.complete` marker exists and
re-hashing the `config.toml` key table reproduces the recorded hash.

`jls` (stdlib `Serialization`) is the built-in zero-dependency format; register
others (`nc`, `jld2`, …) with `DataManifest.Cache.register_format!(ext, save, load)`.
The cross-language DataManifest spec recommends `jld2` as the Julia default;
shipping `jls` as the built-in is a documented, spec-permitted deviation.

## Special keyword arguments

If the wrapped function declares keyword arguments with these names, the macro
gives them extra meaning:

- any `_`-prefixed keyword is a runtime knob: visible in the body, excluded from
  the hash;
- `_metadata_extras` (NamedTuple/Dict/`nothing`) is merged into `metadata.toml`
  without affecting the hash;
- `cache_dir` overrides the artifact location verbatim
  (`<cache_dir>/<cachetype>/[<version>/]<hash>`), bypassing `datacache_dir`
  entirely — useful for keeping one experiment's outputs in a folder of its own.

## Concurrency

Processes producing the same artifact serialize on a `.lock` pidfile next to the
artifact directory, refreshed by the holder while it works. A second process
asking for the same artifact waits, then re-checks the directory and loads what
the first one wrote instead of recomputing it — N workers compute the result
once. Locks left behind by a crashed holder are detected as stale and reclaimed.

Where artifacts are recorded, how a moved or deleted state file recovers, and how
to inspect / prune the cache: see [storage.md](storage.md).

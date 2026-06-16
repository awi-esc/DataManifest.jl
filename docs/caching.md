# Produce-or-load caching (`@cached`)

`@cached` wraps a function so that its result is computed once and saved to
disk; later calls with the same parameters load the saved result (an
**artifact**) instead of recomputing it. The concept — and the Python
`@cached` decorator over the same store — is described on the central site
under [Caching computed
results](https://perrette.github.io/datamanifest/api/#caching-computed-results);
where artifacts land on disk and how to inspect or prune them is part of the
[storage model](https://perrette.github.io/datamanifest/storage/). The cache
key is the SHA-256 of the canonical JSON (RFC 8785) of the hash-affecting
parameters, computed identically by every implementation, so caches are shared
across languages. This page documents the Julia macro.

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

The wrapped function may take positional and/or keyword arguments; each
parameter feeds the cache key by its declared name (splatted `args...` are
rejected, having no fixed name to hash). The macro adds a `cached::Bool=true`
keyword to the function: pass `cached=false` to run the body directly, with no
disk reads or writes.

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
- `db` (optional): a `Database` the whole cache context derives from — gives a
  library its own cache bundle, separate from the host project's folders and
  state; see [library cache
  bundles](https://perrette.github.io/datamanifest/api/#library-cache-bundles-database-scoped-caching)
  on the central site and the [API reference](api.md#caching-the-cached-macro).

Values in the key table may be strings, integers, booleans, finite floats, and
arrays/objects of those. Floats are written in the form Python's `json.dumps`
uses (`1.0` → `1.0`, `1e-5` → `1e-05`). `NaN`, `±Inf`, and nulls
(`nothing`/`missing`) raise an error, since they have no stable JSON form.

## Formats

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

## On disk

Each artifact is a self-describing directory at
`<datacache_dir>/<cachetype>/[<version>/]<hash>/`, holding the artifact file,
a `config.toml` sidecar (the re-hashable key table), a `metadata.toml` sidecar
(provenance), and a `.complete` marker. Processes producing the same artifact
serialize on a `.lock` pidfile, so N workers compute a result once; stale
locks left by a crashed holder are reclaimed (see the `lock_stale_age`
[configuration variable](https://perrette.github.io/datamanifest/configuration/)).
How artifacts are recorded in the state file and how to inspect or prune the
cache from Julia: see [storage](storage.md).

That `.lock` protects the **producer** of the artifact. If you write *additional*
shared files into an already-produced artifact directory (e.g. derived
diagnostics reused by every consumer of the artifact), use
[`with_lock`](api.md#with_lock) to take the same lock so those consumer-side
writes are serialized too — otherwise concurrent consumers race on
check-then-write. `with_lock` (and the lower-level `materialize` it shares the
lock with) are documented under
[Concurrency primitives](api.md#concurrency-primitives-materialize-and-with_lock).

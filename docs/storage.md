# Storage model and the state file

The [README](../README.md#put-data-where-you-want-it) shows the short version;
this page is the full storage reference: the two folder fields, `$`-symbols and
their resolution ladder, the scoped config files, per-dataset overrides, read
pools, and the state file with its maintenance surface.

## Two folder fields

DataManifest storage reduces to **two folder fields**, with nothing derived — the folder you
set IS the location. Since spec-v5 they default to **machine-global** locations: one keyed
store shared across projects for fetched datasets (a dataset key is a globally unique
content identity, so the store deduplicates by construction), and a per-project
(`$project`-namespaced) produced cache — the repository holds only the manifest and the
git-ignored `.datamanifest/` directory:

```toml
datasets_dir  = "$user_data_dir/datamanifest/shared/datasets"            # fetched (default)
datacache_dir = "$user_cache_dir/datamanifest/projects/$project/cached"  # produced (default)
```

```toml
[_META]
schema = 1

[_STORAGE]
datasets_dir  = "datasets"       # repo-local opt-out: fetched data under ./datasets/
datacache_dir = "cached"         # …and the produced cache under ./cached/
scratch       = "$TMPDIR"        # user-defined symbol -> $scratch

[_STORAGE._HOST."login*.hpc.edu"]
scratch = "/scratch/$USER"       # same symbol, host-specific resolution

[my_dataset]
uri = "https://example.com/ds.nc"
# default storage_path is "$datasets_dir/$key"

[in_repo]
uri          = "https://example.com/manual.nc"
storage_path = "data/manual.nc"  # exact path, no $key -> user-managed, never touched by maintenance
```

A **relative** folder is relative to the **project root** (`$repo`); an absolute path, a `~`
path, or a `$symbol`-rooted path is used as written. There is **no scope, no prefix, no
appname, no derived name, and no `store` selector** — to relocate data, point a folder at a
location of your choice in one explicit edit.

## `$`-symbols and the resolution ladder

**`$`-symbols** interpolate in any path. The predefined ones: `$user_data_dir`
(= `platformdirs.user_data_dir()`, e.g. `~/.local/share` — **bare**, no `datamanifest` app
segment), `$user_cache_dir` (`~/.cache`), `$repo` (the project root), and `$project` (the
project **name** — the project-root basename by default, overridable as a bare `project`
field); plus `$USER`/env vars and `~`. Any other bare `[_STORAGE]` key is a **user-defined
symbol** (`scratch = "…"` → `$scratch`), and can be made host-specific via
`[_STORAGE._HOST."<glob>"]`.

**Scoped config files (spec-v5).** Per-machine settings live in two optional,
`[_STORAGE]`-shaped config files instead of the committed manifest:
**`.datamanifest/config.toml`** (per-checkout, git-ignored — the `.datamanifest/` directory
also holds the state file and self-ignores via its own `.gitignore`) and
**`$XDG_CONFIG_HOME/datamanifest/config.toml`** (user-global, default
`~/.config/datamanifest/config.toml`). Both accept the same fields, pools, `project`,
symbols, and `_HOST` sub-tables. Every symbol and field resolves through one ladder (first
match wins; within each file a `_HOST` glob match beats the base value):

> `DATAMANIFEST_<NAME>` env-var → `.datamanifest/config.toml` → manifest
> `[_STORAGE._HOST.<glob>]` → manifest `[_STORAGE]` →
> `~/.config/datamanifest/config.toml` → the built-in default.

In the API, `Storage.config_layers(db.storage_config; project_root=…)` builds the chain;
every resolver (`datasets_dir`, `datacache_dir`, `resolve_symbol`, the pools) accepts either
a single `[_STORAGE]` dict or that vector of layers as `storage_config`.

**Per-dataset `storage_path`.** A dataset's `storage_path` is a path expression (default
`$datasets_dir/$key`) that **replaces both the old `store` selector and `local_path`**:

- containing `$key` ⇒ a **tool-managed** keyed location;
- an exact path **without** `$key` ⇒ **user-managed**, used verbatim, and never touched by
  store maintenance.

There are exactly **two env overrides**, `DATAMANIFEST_DATASETS_DIR` and
`DATAMANIFEST_DATACACHE_DIR` (user symbols override as `DATAMANIFEST_<NAME>`).

> **Sharing fetched data across projects.** Set `datasets_dir = "$user_data_dir/<name>"` (one
> explicit edit). `_PROFILE` is accepted and round-tripped but not applied during resolution —
> use the auto-matched `_HOST`.

## Read pools — reuse, don't re-fetch

**Read pools** (`datasets_pools` / `datacache_pools`): a read pool is an extra **read-only**
location probed for an already-present object before downloading (or recomputing), so a
dataset another project already fetched — or a `@cached` result it already produced — is
reused **in place** rather than re-obtained. A fetch probes the pools after the
recorded/derived location and before downloading; on a hit it verifies the declared `sha256`
(a mismatch is skipped), records the location in the state file, and returns it — the pool is
never written to, and new downloads still land in `datasets_dir` (the gold standard).

```toml
[_STORAGE]
datasets_pools  = ["$user_data_dir/shared/datasets", "~/.cache/Datasets"]  # list of read-only dirs
# datacache_pools = ["$user_data_dir/shared/cached"]                       # same, for @cached artifacts
```

`datasets_pools` is host-composable (`_HOST`) and env-overridable (`DATAMANIFEST_DATASETS_POOLS`,
`pathsep`-separated); **undefined** falls back to the built-in defaults — `$repo/datasets`
(so pre-spec-v5 repo-local data keeps being found and adopted; skipped without a project
root), `$user_data_dir/datamanifest/shared/datasets` (the shared store doubles as the
default read pool, so it self-populates), then the legacy
`$user_data_dir/datamanifest/datasets` and `~/.cache/Datasets` — and an explicit **empty**
list disables it. `datacache_pools` is **opt-in** (undefined ⇒ none).

## The state file (`.datamanifest/state.toml`)

`Datasets.toml` is the committed **spec** — *what* to track and *how* to obtain it. *Where*
each object actually landed on this machine is recorded separately in the **git-ignored**
**`.datamanifest/state.toml`** — the *state file* (regenerable local state, schema 5),
inside the per-checkout `.datamanifest/` directory beside the manifest. One
inventory covers **both** fetched datasets and produced artifacts, under two namespaces. Read
or build one with `CachedIndex` / `read_index` / `register!` / `register_dataset!` /
`write_index`.

```toml
[_META]
schema = 5

# produced artifacts: cachetype[@version] → instances{hash → artifact dir}
[datacache."lgmpre.data.load_20c@v3"]
ref    = "lgmpre.data:load_20c"   # the producing module:function (refreshed across a refactor)
format = "nc"
  [datacache."lgmpre.data.load_20c@v3".instances]
  "83425a30…" = "cached/lgmpre.data.load_20c/v3/83425a30…"   # the full artifact directory

# fetched datasets: storage key → resolved location (+ actual checksum)
[datasets."example.com/foo.nc"]
storage_path = "datasets/example.com/foo.nc"
sha256       = "abc123…"
```

The `datacache` namespace keys each recipe by `(cachetype, version)` (`@` is the reserved
version separator) and maps each variation's parameter `hash` to the **artifact directory** it
was written to — the **params themselves live in each artifact's `config.toml`**, not here.
The `datasets` namespace records each fetched dataset's resolved `storage_path` and **actual**
`sha256`. Registering **accumulates**. The legacy `.datamanifest-state.toml` (pre-spec-v5
sibling) and `cached.toml` paths and the schema 1–4 forms are still read; the first write
relocates the file to the canonical `.datamanifest/state.toml` and migrates the shape
forward.

**Linked `git worktree`s share the main checkout's state file.** A worktree starts without
the git-ignored `.datamanifest/` directory. When the project directory has no state file of
its own and sits inside a linked worktree (`git worktree add`), lookups fall through to the
corresponding directory in the main checkout — reads consult its inventory and writes update
it, so all worktrees of a repository maintain one shared inventory. A state file present in
the worktree itself always takes precedence (create one there to opt a worktree out). The
main checkout is resolved by asking the `git` executable; when `git` is not installed, the
main repository is bare, or the directory is not inside a worktree, lookups stay local.

**Read-first resolution:** resolving where a fetched dataset lives consults the recorded
`storage_path` first — if those bytes are present, a *moved* dataset is found where it really
lives, ahead of the derived `$datasets_dir/$key` rule (a re-download still writes to the
derived directive location). A successful fetch records the resolved location + actual sha256;
a **cache hit self-heals** the inventory (registers a missing variation, refreshes a drifted
recipe `ref`), best-effort and off the hot path — so a deleted state file repopulates as
objects are accessed. The on-disk `config.toml` stays the cache-validity authority;
`metadata.toml` provenance stays write-if-absent (its `[origin].state_file` back-pointer names
the inventory).

## Store maintenance (`inspect_store`)

`inspect_store(db)` enumerates produced artifacts **and** present fetched datasets as one
list of `CacheObject`s (`kind`, `key`/`hash`, `format`, `size`, `created`,
`last_access`, `referenced`), resolving `referenced` from the state file on the
`(cachetype, version, hash)` key. Filter the list and act with `delete_object` /
`move_object` — there is **no automatic garbage collector**; deletion is always an explicit
selection, and only produced (`cached`) artifacts are eligible.
A produced artifact's **last-access** time (`last_access`) is read purely from the filesystem
at inspect time — never written on read — so it is coarse and may track mtime on
`noatime`/`relatime` mounts; `created` is the always-available age signal.

```julia
db = read_dataset("Datasets.toml")
for o in inspect_store(db)
    o.kind == "cached" && o.referenced == false && delete_object(o)   # prune orphaned artifacts
end
```

The [Python `datamanifest` CLI](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
offers the same maintenance from the shell (`list --orphan --delete`, `refresh`, …) over the
same state file.

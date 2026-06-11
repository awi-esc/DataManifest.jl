# Storage: where data lands on disk

The [walkthrough](doc.md) shows the short version. This
page is the full reference: the two storage folders and their defaults, the config
files that change them, path symbols and how a value is looked up, read pools, the
state file, store maintenance, and the advanced corners (per-dataset paths,
host-specific values, git worktrees, frozen configuration snapshots).

## Where data goes

DataManifest writes to exactly two folders, each named by one field:

| Field | Holds | Default |
|---|---|---|
| `datasets_dir` | fetched datasets | `$user_data_dir/datamanifest/shared/datasets` |
| `datacache_dir` | produced (`@cached`) artifacts | `$user_cache_dir/datamanifest/projects/$project/cached` |

Nothing is derived from these values — the folder you set is the location used.

By default both live outside the repository, so a checkout stays small: the
repository holds only the committed manifest (`Datasets.toml`) and the git-ignored
`.datamanifest/` directory (local state, see [the state file](#the-state-file-datamanifeststatetoml)).

The default `datasets_dir` is shared across all projects on the machine. Each
fetched dataset is stored under its **key** — an identifier that is unique across
projects — so two projects that declare the same dataset share one copy. The
default `datacache_dir` is per project (`$project` is the project name).

## Changing the two folders

Set the fields in one of three places (or with the command line, below):

- **`.datamanifest/config.toml`** — per checkout, git-ignored (the `.datamanifest/`
  directory ignores itself via its own `.gitignore`). Use this for settings that
  belong to this machine and this checkout.
- **`Datasets.toml`, under `[_STORAGE]`** — committed with the project. Use this
  for defaults you want every collaborator to get.
- **`~/.config/datamanifest/config.toml`** (more precisely
  `$XDG_CONFIG_HOME/datamanifest/config.toml`) — user-global, applies to all your
  projects.

The two config files take the same shape as the manifest's `[_STORAGE]` table: the
same fields, pools, `project` name, user-defined symbols, and `_HOST` sub-tables.

```toml
[_STORAGE]
datasets_dir  = "datasets"   # keep fetched data in the repo, under ./datasets/
datacache_dir = "cached"     # ...and the produced cache under ./cached/
```

A **relative** folder is relative to the project root. An absolute path, a `~`
path, or a path starting with a `$symbol` is used as written.

The [Python `datamanifest` CLI](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
edits these files for you — it works on the same files the Julia package reads:

```sh
datamanifest config set datacache_dir "/scratch/$USER/cache"    # this checkout
datamanifest config set datasets_dir /pool --global             # this user
datamanifest config set datacache_dir cached --project          # committed default
datamanifest config show
```

Finally, every field can be overridden for one shell session with an environment
variable named `DATAMANIFEST_<NAME>` in upper case — for the two folders,
`DATAMANIFEST_DATASETS_DIR` and `DATAMANIFEST_DATACACHE_DIR`.

## `$`-symbols and the resolution ladder

> The complete list of configuration variables, their scopes, and worked
> examples live on the [configuration page](configuration.md); this section
> explains the path machinery behind them.


A **`$`-symbol** is a named placeholder, written `$name` or `${name}`, that can
appear in any path value. The predefined symbols:

- `$user_data_dir` — the platform user data directory (e.g. `~/.local/share` on
  Linux), with no `datamanifest` segment appended;
- `$user_cache_dir` — the platform user cache directory (e.g. `~/.cache`);
- `$repo` — the project root;
- `$project` — the project name: the basename of the project root by default,
  overridable by setting a bare `project` field in `[_STORAGE]` or a config file.

A `$NAME` that matches none of these resolves as the environment variable `NAME`
(e.g. `$USER`); a leading `~` expands to your home directory. Any other bare key
in `[_STORAGE]` or a config file defines a new symbol:

```toml
[_STORAGE]
scratch       = "$TMPDIR"            # defines $scratch
datacache_dir = "$scratch/myproj"    # and uses it
```

The **resolution ladder** is the fixed order in which a field or symbol is looked
up; the first place that defines it wins:

> `DATAMANIFEST_<NAME>` environment variable
> → `.datamanifest/config.toml` (checkout)
> → manifest `[_STORAGE]`
> → `~/.config/datamanifest/config.toml` (user-global)
> → the built-in default.

Within each file, a matching host-specific value (a `_HOST` sub-table, see
[below](#host-specific-values-_host)) beats the file's base value. Symbols resolve
through the same ladder, and a value may itself contain further symbols.

Besides paths and symbols, two scalar settings ride the same ladder:

- `canonical` (boolean) — write the manifest in a byte-identical canonical form;
  see [the main page](doc.md);
- `lock_stale_age` (seconds, default 30) — how old a lock file must be before it
  is considered stale.

## Read pools — reuse, don't re-fetch

A **read pool** is an extra read-only folder that is checked for an
already-present object before downloading (or recomputing). If another project on
the machine already fetched a dataset — or already produced a `@cached` result —
it is used in place rather than obtained again.

A fetch checks the pools after the recorded/derived location and before
downloading. On a hit it verifies the declared `sha256` (a mismatch is skipped),
records the location in the state file, and returns the path. A pool is never
written to; new downloads still land in `datasets_dir`.

```toml
[_STORAGE]
datasets_pools  = ["/pool/datasets", "~/team/datasets"]   # list of read-only dirs
# datacache_pools = ["/pool/cached"]                      # same, for @cached artifacts
```

Both fields accept host-specific values (`_HOST`) and environment overrides
(`DATAMANIFEST_DATASETS_POOLS` / `DATAMANIFEST_DATACACHE_POOLS`, separated by the
platform path separator). When `datasets_pools` is left undefined, a built-in
list is probed, so data fetched into a repo-local `datasets/` folder or into an
older default location is still found:

1. `$repo/datasets` (skipped when no project root is known),
2. `$user_data_dir/datamanifest/shared/datasets` (the default store doubles as the
   default pool, so it self-populates),
3. `$user_data_dir/datamanifest/datasets`,
4. `~/.cache/Datasets`.

An explicit empty list (`datasets_pools = []`) disables pooling. `datacache_pools`
has no built-in list: undefined means none.

## The state file (`.datamanifest/state.toml`)

`Datasets.toml` is the committed spec — *what* to track and *how* to obtain it.
*Where* each object actually landed on this machine is recorded separately in the
**state file**, `.datamanifest/state.toml`: a git-ignored, regenerable inventory
(schema 5) kept in the `.datamanifest/` directory beside the manifest. One file
covers both fetched datasets and produced artifacts, under two namespaces. Read or
build one with `CachedIndex` / `read_index` / `register!` / `register_dataset!` /
`write_index`.

```toml
[_META]
schema = 5

# produced artifacts: cachetype[@version] → instances{hash → artifact dir}
[datacache."lgmpre.data.load_20c@v3"]
ref    = "lgmpre.data:load_20c"   # the producing module:function
format = "nc"
  [datacache."lgmpre.data.load_20c@v3".instances]
  "83425a30…" = "cached/lgmpre.data.load_20c/v3/83425a30…"   # the artifact directory

# fetched datasets: storage key → resolved location (+ actual checksum)
[datasets."example.com/foo.nc"]
storage_path = "datasets/example.com/foo.nc"
sha256       = "abc123…"
```

The `datacache` namespace keys each recipe by `(cachetype, version)` (`@` is the
reserved version separator) and maps each variation's parameter `hash` to the
artifact directory it was written to — the parameters themselves live in each
artifact's `config.toml`, not here. The `datasets` namespace records each fetched
dataset's resolved `storage_path` and actual `sha256`. Registering accumulates;
older state-file names (`.datamanifest-state.toml`, `cached.toml`) and shapes
(schema 1–4) are still read, and the first write moves the file to
`.datamanifest/state.toml` and migrates the shape forward.

**Read-first resolution.** Resolving where a fetched dataset lives consults the
recorded `storage_path` first — if those bytes are present, a moved dataset is
found where it really lives, ahead of the derived `$datasets_dir/$key` rule (a
re-download still writes to the derived location). A successful fetch records the
resolved location and actual sha256, and a cache hit repairs the inventory as a
side effect (it registers a missing variation and refreshes a drifted recipe
`ref`, best-effort and off the hot path) — so a deleted state file repopulates as
objects are accessed. The artifact's on-disk `config.toml` remains the authority
for cache validity; `metadata.toml` provenance is written only if absent (its
`[origin].state_file` entry points back to the inventory).

## Store maintenance (`inspect_store`)

`inspect_store(db)` enumerates produced artifacts and present fetched datasets as
one list of `CacheObject`s (`kind`, `key`/`hash`, `format`, `size`, `created`,
`last_access`, `referenced`), resolving `referenced` from the state file. Filter
the list and act with `delete_object` / `move_object`. There is no automatic
garbage collector — deletion is always an explicit selection, and only produced
(`cached`) artifacts are eligible.

A produced artifact's `last_access` time is read from the filesystem at inspect
time and never written on read, so it is coarse and may track the modification
time on `noatime`/`relatime` mounts; `created` is the always-available age signal.

```julia
db = read_dataset("Datasets.toml")
for o in inspect_store(db)
    o.kind == "cached" && o.referenced == false && delete_object(o)   # prune orphaned artifacts
end
```

The [Python `datamanifest` CLI](https://github.com/perrette/datamanifest/blob/main/docs/cli.md)
offers the same maintenance from the shell (`list --orphan --delete`, `refresh`,
…) over the same state file.

## Per-dataset `storage_path`

A dataset's `storage_path` is a path expression that says where that one dataset
goes; the default is `$datasets_dir/$key`. The presence of `$key` decides who
manages the file:

- containing `$key` — a **tool-managed** keyed location;
- an exact path without `$key` — **user-managed**: used verbatim and never touched
  by store maintenance.

```toml
[in_repo]
uri          = "https://example.com/manual.nc"
storage_path = "data/manual.nc"   # exact path, no $key → user-managed
```

## Host-specific values (`_HOST`)

Any `[_STORAGE]` table — in the manifest or in a config file — can carry a
`_HOST` sub-table whose keys are hostname globs (`*` and `?` wildcards). When the
current hostname matches a glob, the values under it beat the file's base values.
This lets one committed manifest serve machines with different filesystems:

```toml
[_STORAGE]
scratch = "$TMPDIR"

[_STORAGE._HOST."login*.hpc.edu"]
scratch = "/scratch/$USER"        # same symbol, resolved differently on the cluster
```

The CLI equivalent is `datamanifest config set scratch '/scratch/$USER' --host
"login*.hpc.edu"`.

## Git worktrees

A linked worktree (`git worktree add`) starts without the git-ignored
`.datamanifest/` directory, so by default it shares the main checkout's:

- **Config:** when a worktree has no `.datamanifest/config.toml` of its own, the
  checkout rung of the ladder reads the main checkout's file. A config file
  present in the worktree itself always wins.
- **State file:** when the worktree has no state file of its own, reads consult
  the main checkout's inventory and writes update it, so all worktrees of a
  repository maintain one shared inventory. A state file present in the worktree
  takes precedence — create one there to opt a worktree out.

The main checkout is found by asking the `git` executable. When `git` is not
installed, the main repository is bare, or the directory is not inside a linked
worktree, lookups stay local.

## Frozen configuration snapshots

In the API, the ladder's inputs are captured once per `Database`: when a
`Database` is materialized it takes a `Storage.ConfigSnapshot` — the three file
layers (checkout config, manifest `[_STORAGE]`, user config) together with the
environment and hostname — so every config variable has one well-defined value
for the Database's lifetime, even if files or environment change underneath.

`freeze_config!(db)` re-reads the files and environment deliberately. Assigning
`db.storage_config` or `db.datasets_toml` invalidates the snapshot; it is frozen
again on next use.

Every resolver (`datasets_dir`, `datacache_dir`, `resolve_symbol`, the pools)
accepts as `storage_config` a single `[_STORAGE]` dict, a vector of layers
(`Storage.config_layers`), or a frozen snapshot. A snapshot is authoritative: its
captured environment and host replace the resolver's own inputs, so resolving in
another context (e.g. on a remote machine) means building that context's own
snapshot.

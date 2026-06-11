# Configuration

This page lists every configuration variable, the places a value can be set
(its *scopes*), and the rule that decides which value wins. The details of
*what the storage settings mean* live in [storage.md](storage.md); this page is
the one place that shows the whole configuration system at a glance.

The guiding principle: the manifest (`Datasets.toml`) is committed and shared
with collaborators, so it carries only project-wide intent. Anything
machine-specific — where data lands on *this* computer, personal preferences —
belongs in git-ignored config files, so it never leaks into the repository.

## The scopes

A value can be set in five places. From the most specific to the most general:

| Scope | Where | Shared? | Typical use |
|---|---|---|---|
| Environment variable | `DATAMANIFEST_<NAME>` (upper-cased variable name) | per process | one-off overrides, CI, tests |
| Checkout config | `<project>/.datamanifest/config.toml` (git-ignored) | this clone only | per-machine choices for one project |
| Manifest | `[_STORAGE]` table in `Datasets.toml` (committed) | every collaborator | project-wide intent |
| User config | `~/.config/datamanifest/config.toml` | every project of this user | machine-wide preferences |
| Built-in default | — | — | what you get without any configuration |

Two refinements:

- **Host-specific values.** Each of the three file scopes accepts a
  `[_HOST."<glob>"]` sub-table whose values apply only on matching hostnames
  (`*` and `?` wildcards). Within a file, a `_HOST` match beats the base value.
  This is how one committed manifest serves a laptop and an HPC cluster at
  once.
- **Git worktrees.** A linked `git worktree` starts without the git-ignored
  `.datamanifest/` directory, so when a worktree has no checkout config of its
  own, the main checkout's file is read instead. A config file created in the
  worktree itself takes precedence.

## How a value is resolved

For a variable `name`, the first match wins, top to bottom:

1. the `DATAMANIFEST_<NAME>` environment variable;
2. the checkout config (`_HOST` match first, then the base value);
3. the manifest's `[_STORAGE._HOST."<glob>"]`, then `[_STORAGE]`;
4. the user config (`_HOST` match first, then base);
5. the built-in default.

The whole ladder — environment included — is evaluated **once, when a
`Database` is materialized** (when the manifest is read). The result is a
frozen snapshot, so every variable has one well-defined value for the
Database's lifetime; editing a config file or the environment afterwards does
not silently retarget an existing session. To pick up changes, re-read the
manifest or call `freeze_config!(db)`. Command-line invocations read the
configuration afresh on every run, so edits always apply to the next command.

## Editing configuration

Edit the TOML files directly, or use the `datamanifest` command-line tool
(from the [Python package](https://github.com/perrette/datamanifest), which
reads and writes the same files):

```bash
datamanifest config show                       # resolved values + each scope's raw rules
datamanifest config set canonical true         # checkout config (the default scope)
datamanifest config set datasets_dir /scratch/data --global    # user config
datamanifest config set datacache_dir cached --project        # committed [_STORAGE]
datamanifest config set datasets_dir /work/data --host 'login*.hpc.org'
datamanifest config unset canonical            # remove from a scope
```

## The variables

| Variable | Type | Default | What it does |
|---|---|---|---|
| `datasets_dir` | path expression | `$user_data_dir/datamanifest/shared/datasets` | Where fetched datasets are stored. See [storage.md](storage.md). |
| `datacache_dir` | path expression | `$user_cache_dir/datamanifest/projects/$project/cached` | Where [`@cached`](caching.md) artifacts are stored. |
| `datasets_pools` | list of path expressions | built-in list | Extra read-only places probed for already-present datasets before downloading. See [read pools](storage.md). |
| `datacache_pools` | list of path expressions | none | Same, for `@cached` artifacts. |
| `project` | name | basename of the project root | The project's name — the `$project` symbol, which namespaces the default cache folder. |
| `canonical` | boolean | `false` | Pipe every manifest write through the Python `datamanifest format` command, so both tools produce byte-identical files. See [the walkthrough](doc.md). |
| `lock_stale_age` | seconds | `30` | How old a materialization lock may grow (without heartbeat) before a waiting process reclaims it. |

The environment-variable form is always `DATAMANIFEST_` + the upper-cased
name: `DATAMANIFEST_DATASETS_DIR`, `DATAMANIFEST_CANONICAL`,
`DATAMANIFEST_LOCK_STALE_AGE`, … List-valued variables use the platform path
separator in their environment form (`DATAMANIFEST_DATASETS_POOLS="/a:/b"`).

Beyond these, **any other bare key** in `[_STORAGE]` or a config file defines a
**user symbol**: `scratch = "/scratch/$USER"` makes `$scratch` available inside
path expressions, host-composable via `_HOST` like everything else. Tools
ignore keys they do not understand, so the same files can carry fields used by
only one tool (the Python tool, for example, reads a `default_remote` for its
transfer commands).

## Examples

A checkout config that keeps one project's data inside the repository and
opts into canonical manifest output:

```toml
# <project>/.datamanifest/config.toml  (git-ignored)
datasets_dir = "datasets"
canonical = true
```

A committed manifest that names the project and routes data to a shared
filesystem on the cluster only:

```toml
# Datasets.toml
[_STORAGE]
project = "lgm-recons"

[_STORAGE._HOST."*.hpc.org"]
datasets_dir = "/work/shared/datasets"
```

A user config that relocates every project's cache to a big disk:

```toml
# ~/.config/datamanifest/config.toml
datacache_dir = "/data/$USER/datamanifest/$project/cached"
```

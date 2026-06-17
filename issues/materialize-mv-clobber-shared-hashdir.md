# `materialize` whole-dir `mv` clobbers sibling artifacts in a shared hash dir

**Severity:** data-loss (silent) for any two `@cached` producers that share a hash
directory. Found 2026-06-17 (v0.36.1) via LGMRecons; worked around downstream, but
the defect is in DataManifest and should be fixed regardless.

## Symptom

When two distinct `@cached` producers resolve to the **same** hash directory
(same `cachetype` + same key ⇒ same `dir`, differing only in `basename`), the
second producer's write **destroys the first's artifact**. Observed in LGMRecons:
`_compute_prior_chain` (basename `data/prior_chains`) and `_compute_posterior_chain`
(basename `data/posterior_chains`), both `cachetype="lgm"` with an identical key,
target one `lgm/<hash>/` dir. After a run, `data/prior_chains.*` is **gone** —
across 93 dirs there were 28 `posterior_chains.nc` and **zero** `prior_chains.*`.
Every re-run then re-samples the (expensive) prior because its artifact never
survives.

## Root cause

`materialize` (PipeLines.jl ~514-547) stages the produce into a sibling
`<dir>.tmp` and then `mv(tmp, dir; force=true)`. Julia's `mv(...; force=true)`
onto an **existing directory removes the whole target first**, then renames the
staging dir into place. So the second producer — whose staging dir contains only
*its own* artifact — replaces the directory wholesale, deleting the first
producer's artifact (and its config/metadata for that basename).

Verified empirically: after the posterior write, the dir contains only
`posterior_chains.nc`; the prior file is gone.

## Fix (suggested)

`materialize` should **merge** a produce into an existing complete dir rather than
whole-dir replace: move/overwrite only the produced artifact (and merge the
state/recipe) into the existing directory, leaving sibling artifacts intact.
Alternatively, detect a pre-existing complete dir with a *different* basename and
refuse-or-merge instead of clobbering. Either way, two `@cached` siblings sharing
a hash dir must coexist.

## Downstream workaround (not a fix)

LGMRecons gave the prior chain its own `cachetype="lgm_prior"` so the two no longer
share a dir (commit `d1b1ae90` on awi-esc/LGMDataAssim). That sidesteps the clobber
for that one pair but does not fix the general defect — any future pair of siblings
in one hash dir will hit it.

## Repro sketch

Two `@cached` functions with the same `cachetype`+key but different `basename`,
called in sequence into the same dir; assert both artifacts exist afterward (they
won't — only the last survives).

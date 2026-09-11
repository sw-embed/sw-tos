# Published storage layout

`storage-layout.json` is a snapshot of what this build stores, in the columnar
contract pinned by `sw-ml-study/sw-mlpl/docs/storage-layout-viz.md`. It is here
so another repo can develop against real SWTOS data without building SWTOS.

It is a snapshot, not a golden file. The figures are whatever build produced
it, and `provenance.revision` says which tree that was. Refresh it from a clean
tree with

    just storage-layout-publish

A dirty tree publishes a snapshot marked `-dirty`, which nothing can be traced
back to; that is why the recipe says to run it clean rather than silently
recording a hash that does not describe the sources.

`just storage-layout-smoke` holds this file to the same contract as freshly
generated output. That is what stops it going *structurally* stale — the kind
of staleness that breaks a consumer — while letting its numbers age.

## One thing a consumer must handle

`region_kind` includes `padding`: the bytes between an image and the next block
boundary. It is deliberately not `free`, because unused capacity and the cost
of block alignment are different facts and a viewer that colours them alike
hides what alignment costs. A palette keyed by kind needs a `padding` row.

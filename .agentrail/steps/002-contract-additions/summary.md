Shipped in 5c4a24e (emitter, validator, publish recipe) and a08d886 (the
published artifact). Gate 58/58 on both.

  examples/viz/storage-layout.json
  sha256 58d29496c75efaa95567d0208ead48dc4c83797c86f2a6952dfc78d1ce748a84
  provenance {producer: sw-tos, revision: 5c4a24e}

The contract additions: schema "sw-ml-study.system-layout"; provenance
carrying the producer revision, with a dirty tree marked as such because a
bare hash would claim a snapshot came from committed sources when it did not;
region_id from the catalog ordinal rather than document position, so adding a
program does not move a viewer's selection; and a describes edge from the
catalog to each stored extent. loads-to needs RAM and belongs to the runtime
snapshot rather than being invented here.

The lesson worth keeping: running the consumer beat reading the contract. The
document satisfied sw-mlpl's written contract, and their reference script
still hard-errored on it -- select_rows is strict and their palette had no
`padding` row, because their own fixture folds padding into free. Real data
has two padding regions. Reading their doc would never have found it; running
examples/viz/render_native3d.mlpl against the real artifact found it in one
command. They have since added the palette row (their 3312e91a), and the
chain now runs: their geometry library builds centers [8,3] and colors [8,4]
from the published artifact.

Holding the line on `padding` as its own kind was right. Seven of the 372
bytes used are block alignment; folding them into "free" would have hidden
exactly what this visualization exists to show.

The validator is deliberately reusable (tests/validate-storage-layout.py):
it checks the freshly generated layout against the image it describes, and
the published sample against the contract alone, since a snapshot's numbers
age but its shape must not.

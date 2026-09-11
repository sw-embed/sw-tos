# Saga: storage-layout-viz

sw-tos's part of a three-repo coordinated demo: an interactive 3D view of a
system's storage and memory layout drawn as stacks of classified blocks. Source
vision: `../../sw-ml-study/demo-extensions/docs/research.txt`.

Architecture: `sw-tos -> storage-layout.json -> MLPL viz script -> native3d
extension -> 3D viewer`. Boundary: SWTOS knows storage semantics; MLPL knows
visualization semantics; native3d knows graphics. **sw-tos emits data and draws
nothing.** Nothing downstream learns the catalog format, and no part of this
runs on the target -- these are host-side build tools reading build artifacts.

The data contract is COLUMNAR (struct-of-arrays), pinned by sw-mlpl in
`../../sw-ml-study/sw-mlpl/docs/storage-layout-viz.md`: every `region_*` array
has length N and is index-aligned, every `space_*` array has length S, and
`spaces[i]` is the key `region_space` joins on. That is not a style preference:
MLPL's `parse_json` ingests homogeneous arrays and string lists today, while an
array-of-objects would need a language feature that does not exist. Emitting
rows here would push the cost onto the consumer.

Parallel repos: `../../sw-ml-study/sw-mlpl` owns the MLPL viz library and the
one classification primitive; `../../sw-ml-study/demo-extensions` owns the
native3d renderer.

Every figure comes from the modules the build and the validator already use
(`cor24-storage.py`, `cor24-image.py`, the monitor's process table), never
recomputed, so the picture cannot drift from the system it claims to describe.

## Steps

1. layout-emitter -- `scripts/storage-layout.py` emitting
   `build/storage-layout.json` in the columnar contract: header, catalog
   records, stored C24IMG extents, block-alignment padding and free capacity,
   with `padding` kept distinct from `free` so the alignment cost stays
   visible. A contract test (`tests/test-storage-layout.sh`) that checks what
   must not change -- columns aligned, regions tiling the whole capacity with
   no gap or overlap, totals agreeing with the image -- rather than the numbers,
   which change whenever a program is added. Registered in the acceptance gate.
   Phase 1 of the research doc: proves the pipeline on a static layout.

2. runtime-snapshot -- `build/runtime-layout.json`: the same columnar contract
   for what the *running* system holds. New spaces for EBR and system RAM; new
   region kinds for a process image, its stack, its state record, the
   executable boundary, the high-water mark and reclaimed space. The figures
   come from the process table the monitor already reads, so a snapshot and
   `mon` cannot disagree. Phase 2 of the research doc.

3. stream-events -- te-rs emits snapshot events as they happen (process spawn,
   image load, allocation, exit, reclaim) so the viewer animates the system
   rather than re-reading a file. Phase 3, and the one piece that touches the
   frontend rather than the build tools.

4. coordinate-and-close -- relay what sw-tos provides and consumes to the
   sw-mlpl and demo-extensions agents, document the emitters in
   `docs/`, and close.

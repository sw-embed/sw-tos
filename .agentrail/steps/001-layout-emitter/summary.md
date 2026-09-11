scripts/storage-layout.py emits build/storage-layout.json in sw-mlpl's columnar
contract; tests/test-storage-layout.sh checks the contract and runs in the gate
as storage-layout-smoke (58/58). Commit 19a4ee7.

What the current build yields: 8 regions over the W25Q32's 4 MiB -- an 8-byte
header, 240 bytes of catalog records, three stored images (embedded-hello,
embedded-ping, cpu-hog) with two 3-4 byte padding regions between them, and the
rest free. 372 bytes used. Padding is emitted as its own kind so the alignment
cost stays visible; sw-mlpl's fixture folds it into "free", which their
classifier should be told about.

Two things worth carrying forward:

The columnar shape was verified against the real interpreter, not just the
doc: mlpl-repl parses the emitted file, string columns arrive as string lists,
numeric columns as vectors, and floor(region_start / space_block) runs
elementwise. read_text is sandboxed to the script's directory, and both
read_text and record_get are Result-speaking, so the file must sit beside the
script and every access needs unwrap.

The test is a contract test on purpose. The numbers change whenever a program
is added; what must not change is that columns stay index-aligned, regions tile
the whole capacity with no gap or overlap, and the totals match the image. It
was mutation-checked -- a dropped column, a one-region gap, a stretched
capacity are each caught -- because a test that has only ever passed proves
nothing.

Emitted but not in the pinned contract: space_used, and program_* columns
(length P, not N) so that catalogued programs with no stored image stay
visible. A provider flag (w25q32/sdcard/resident) picks the space key and
capacity; only w25q32 is exercised.

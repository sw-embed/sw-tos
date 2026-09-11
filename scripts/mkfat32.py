#!/usr/bin/env python3
"""Build a FAT32 SD-card image that Linux, macOS and SWTOS all read.

Why this exists rather than mkfs.vfat or newfs_msdos: those are different
programs with different flags on the two hosts SWTOS is developed on, and
neither is present everywhere the test suite runs. A few hundred lines of
Python produce the same on-disk structure with no dependencies, so the gate
builds an identical card on either machine.

The output is a raw disk image -- no partition table, a "superfloppy" layout,
which is what SD cards up to 32 GB ship as and what the emulator's sdcard
device reads. Mount it to check:

    macOS:  hdiutil attach -imagekey diskimage-class=CRawDiskImage <image>
    Linux:  mount -o loop <image> /mnt

FAT32 is the choice for 4-64 GB media because it is the SDHC standard, every
host reads and writes it, and its structures are simple enough to walk from a
24-bit machine with a 512-byte buffer. exFAT is what 64 GB cards ship with,
but it needs an allocation bitmap, an up-case table and checksums; a 64 GB
card reformatted FAT32 works on every host and is the simpler target.

Short names only. Long filenames are a VFAT extension stored in extra
directory entries, and reading them is a separate piece of work; a name
written here fits 8.3 so that what SWTOS lists is what the host shows.
"""

import argparse
import struct
import sys
from pathlib import Path

SECTOR = 512
# The specification's floor. Fewer clusters than this and a volume is FAT16 by
# definition, whatever its boot sector claims, and hosts will read it as one.
MIN_CLUSTERS = 65525
FREE, END = 0x00000000, 0x0FFFFFFF
ATTR_DIRECTORY, ATTR_VOLUME_ID = 0x10, 0x08


def short_name(name: str) -> bytes:
    """Encode one 8.3 name into the eleven padded bytes a directory entry holds."""
    # "." and ".." are stored as themselves, left-justified. They are not 8.3
    # names that happen to look odd; they are the two literal exceptions.
    if name in (".", ".."):
        return f"{name:<11}".encode("ascii")
    stem, _, ext = name.upper().partition(".")
    if not stem or len(stem) > 8 or len(ext) > 3:
        raise ValueError(f"{name!r} is not an 8.3 name")
    bad = set(stem + ext) - set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~!#$%&()@^{}")
    if bad:
        raise ValueError(f"{name!r} contains {''.join(sorted(bad))!r}")
    return f"{stem:<8}{ext:<3}".encode("ascii")


def directory_entry(name: str, attr: int, cluster: int, size: int) -> bytes:
    """One 32-byte entry. Timestamps are fixed, so an image is reproducible."""
    return struct.pack(
        "<11sBBBHHHHHHHI",
        short_name(name),
        attr,
        0,      # reserved
        0,      # creation time, tenths
        0,      # creation time
        0x0021, # creation date: 1980-01-01, the epoch FAT counts from
        0x0021, # last access date
        cluster >> 16,
        0,      # write time
        0x0021, # write date
        cluster & 0xFFFF,
        size,
    )


class Fat32:
    def __init__(self, sectors: int, sectors_per_cluster: int, label: str,
                 allow_small: bool = False):
        self.sectors_per_cluster = sectors_per_cluster
        self.reserved = 32
        # Solve for a FAT big enough to describe the clusters that remain once
        # the FAT itself is accounted for. One pass over an estimate converges,
        # because shrinking the data area only ever shrinks the FAT.
        usable = sectors - self.reserved
        clusters = usable // sectors_per_cluster
        for _ in range(4):
            fat_sectors = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
            clusters = (usable - fat_sectors * 2) // sectors_per_cluster
        self.fat_sectors = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        self.clusters = clusters
        if clusters < MIN_CLUSTERS and not allow_small:
            raise ValueError(
                f"{clusters} clusters is below FAT32's {MIN_CLUSTERS} minimum; "
                f"use a larger image or fewer sectors per cluster"
            )
        self.sectors = sectors
        self.label = label
        self.data_start = self.reserved + self.fat_sectors * 2
        self.fat = [FREE] * (clusters + 2)
        self.fat[0], self.fat[1] = 0x0FFFFFF8, END
        self.data = bytearray(clusters * sectors_per_cluster * SECTOR)
        self.next_free = 2

    def allocate(self, byte_count: int) -> int:
        """Claim a cluster chain and return its first cluster."""
        per = self.sectors_per_cluster * SECTOR
        needed = max(1, (byte_count + per - 1) // per)
        if self.next_free + needed > self.clusters + 2:
            raise ValueError("image is full")
        first = self.next_free
        for index in range(needed):
            cluster = first + index
            self.fat[cluster] = END if index == needed - 1 else cluster + 1
        self.next_free += needed
        return first

    def write_cluster_chain(self, first: int, payload: bytes) -> None:
        per = self.sectors_per_cluster * SECTOR
        cluster, offset = first, 0
        while offset < len(payload):
            base = (cluster - 2) * per
            chunk = payload[offset : offset + per]
            self.data[base : base + len(chunk)] = chunk
            offset += per
            cluster = self.fat[cluster]

    def boot_sector(self, root_cluster: int) -> bytes:
        sector = bytearray(SECTOR)
        sector[0:3] = b"\xeb\x58\x90"           # jump, as every host expects
        sector[3:11] = b"SWTOS1.0"
        struct.pack_into(
            "<HBHBHHBHHHII",
            sector, 11,
            SECTOR,                  # bytes per sector
            self.sectors_per_cluster,
            self.reserved,
            2,                       # two FATs, which is what hosts assume
            0,                       # root entries: zero marks FAT32
            0,                       # small total sectors: zero marks "see below"
            0xF8,                    # fixed media
            0,                       # FAT16 sectors per FAT: zero marks FAT32
            63, 255,                 # geometry, cosmetic on a card
            0,                       # hidden sectors: none, this is unpartitioned
            self.sectors,
        )
        struct.pack_into(
            "<IHHIHH",
            sector, 36,
            self.fat_sectors,
            0,                       # flags: both FATs mirrored
            0,                       # version
            root_cluster,
            1,                       # FSInfo sector
            6,                       # backup boot sector
        )
        sector[64] = 0x80            # drive number
        sector[66] = 0x29            # extended boot signature
        struct.pack_into("<I", sector, 67, 0x53575444)
        sector[71:82] = f"{self.label:<11}".encode("ascii")[:11]
        sector[82:90] = b"FAT32   "
        sector[510:512] = b"\x55\xaa"
        return bytes(sector)

    def fsinfo_sector(self) -> bytes:
        sector = bytearray(SECTOR)
        struct.pack_into("<I", sector, 0, 0x41615252)
        struct.pack_into("<I", sector, 484, 0x61417272)
        struct.pack_into("<I", sector, 488, self.clusters - (self.next_free - 2))
        struct.pack_into("<I", sector, 492, self.next_free)
        sector[508:512] = b"\x00\x00\x55\xaa"
        return bytes(sector)

    def image(self, root_cluster: int) -> bytes:
        out = bytearray(self.reserved * SECTOR)
        out[0:SECTOR] = self.boot_sector(root_cluster)
        out[SECTOR : 2 * SECTOR] = self.fsinfo_sector()
        # The backup at sector 6 is what a host repairs from, so it must match.
        out[6 * SECTOR : 7 * SECTOR] = self.boot_sector(root_cluster)
        out[7 * SECTOR : 8 * SECTOR] = self.fsinfo_sector()
        table = bytearray(self.fat_sectors * SECTOR)
        for index, value in enumerate(self.fat):
            struct.pack_into("<I", table, index * 4, value)
        return bytes(out + table + table + self.data)


def build(path: Path | None, size_mib: int, sectors_per_cluster: int, label: str,
          files: list[tuple[str, bytes]],
          directories: list[str] | list[tuple[str, list[tuple[str, bytes]]]],
          allow_small: bool = False) -> tuple[Fat32, bytes]:
    """Format a volume. A directory may carry files of its own, given as
    (name, [(filename, contents), ...]) instead of a bare name."""
    volume = Fat32((size_mib * 2**20) // SECTOR, sectors_per_cluster, label,
                   allow_small)
    root = volume.allocate(1)
    entries = bytearray(directory_entry(label, ATTR_VOLUME_ID, 0, 0))

    for item in directories:
        name, contents = item if isinstance(item, tuple) else (item, [])
        cluster = volume.allocate(1)
        # Every subdirectory carries "." and ".." as its first two entries, and
        # a host fsck reports a directory without them as damaged. ".." names
        # cluster 0 when the parent is the root.
        body = bytearray()
        body += directory_entry(".", ATTR_DIRECTORY, cluster, 0)
        body += directory_entry("..", ATTR_DIRECTORY, 0, 0)
        for child, payload in contents:
            child_cluster = volume.allocate(len(payload)) if payload else 0
            if payload:
                volume.write_cluster_chain(child_cluster, payload)
            body += directory_entry(child, 0x20, child_cluster, len(payload))
        per = volume.sectors_per_cluster * SECTOR
        volume.write_cluster_chain(cluster, bytes(body).ljust(per, b"\0"))
        entries += directory_entry(name, ATTR_DIRECTORY, cluster, 0)

    for name, payload in files:
        cluster = volume.allocate(len(payload)) if payload else 0
        if payload:
            volume.write_cluster_chain(cluster, payload)
        entries += directory_entry(name, 0x20, cluster, len(payload))

    per = volume.sectors_per_cluster * SECTOR
    if len(entries) > per:
        raise ValueError("root directory needs more than one cluster")
    volume.write_cluster_chain(root, bytes(entries).ljust(per, b"\0"))
    image = volume.image(root)
    if path is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(image)
    return volume, image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", type=Path)
    parser.add_argument("--size-mib", type=int, default=48)
    parser.add_argument("--sectors-per-cluster", type=int, default=1)
    parser.add_argument("--label", default="SWTOS")
    parser.add_argument("--file", action="append", default=[], metavar="NAME=TEXT",
                        help="a file holding the given text")
    parser.add_argument("--copy", action="append", default=[], metavar="NAME=PATH",
                        help="a file holding the contents of a host file")
    parser.add_argument("--dir", action="append", default=[], metavar="NAME")
    args = parser.parse_args()

    files: list[tuple[str, bytes]] = []
    for spec in args.file:
        name, _, text = spec.partition("=")
        files.append((name, text.encode("ascii").replace(b"\\n", b"\n")))
    for spec in args.copy:
        name, _, source = spec.partition("=")
        files.append((name, Path(source).read_bytes()))

    try:
        volume, _ = build(args.image, args.size_mib, args.sectors_per_cluster,
                          args.label, files, args.dir)
    except ValueError as error:
        print(f"mkfat32: {error}", file=sys.stderr)
        return 1

    print(f"{args.image}: {args.size_mib} MiB, {volume.clusters} clusters of "
          f"{volume.sectors_per_cluster * SECTOR} B, "
          f"root directory at sector {volume.data_start}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

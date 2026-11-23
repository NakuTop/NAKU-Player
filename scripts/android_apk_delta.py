#!/usr/bin/env python3
"""Write gzip-compressed GDIFF v4 from the exact bytes of two signed APKs."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import mmap
from pathlib import Path
import struct
import zipfile

BLOCK = 64 * 1024
MAGIC = bytes.fromhex('d1ffd1ff04')


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def offset(data, entry):
    pos = entry.header_offset
    if data[pos:pos + 4] != b'PK\x03\x04':
        raise ValueError('Invalid APK local file header')
    name, extra = struct.unpack_from('<HH', data, pos + 26)
    start = pos + 30 + name + extra
    if start + entry.compress_size > len(data):
        raise ValueError('Compressed entry extends beyond APK')
    return start


def copies(old, new, old_zip, new_zip):
    """Find reusable compressed members and aligned blocks within changed members."""
    entries = {entry.filename: entry for entry in old_zip.infolist()}
    for entry in sorted(new_zip.infolist(), key=lambda row: row.header_offset):
        prior = entries.get(entry.filename)
        if prior is None or min(prior.compress_size, entry.compress_size) < 32:
            continue
        src, dst = offset(old, prior), offset(new, entry)
        shared = min(prior.compress_size, entry.compress_size)
        run = None
        for at in range(0, shared, BLOCK):
            count = min(BLOCK, shared - at)
            if new[dst + at:dst + at + count] == old[src + at:src + at + count]:
                if run is None:
                    run = at
            elif run is not None:
                yield dst + run, src + run, at - run
                run = None
        if run is not None:
            yield dst + run, src + run, shared - run


def literal(stream, new, begin, end):
    while begin < end:
        count = min(1024 * 1024, end - begin)
        if count <= 246:
            stream.write(bytes([count]))
        elif count <= 65535:
            stream.write(struct.pack('>BH', 247, count))
        else:
            stream.write(struct.pack('>Bi', 248, count))
        stream.write(new[begin:begin + count])
        begin += count


def make_patch(base: Path, target: Path, patch: Path) -> None:
    with (base.open('rb') as base_file, target.open('rb') as target_file,
          mmap.mmap(base_file.fileno(), 0, access=mmap.ACCESS_READ) as old,
          mmap.mmap(target_file.fileno(), 0, access=mmap.ACCESS_READ) as new,
          zipfile.ZipFile(base_file) as old_zip, zipfile.ZipFile(target_file) as new_zip,
          patch.open('wb') as packed,
          gzip.GzipFile(fileobj=packed, filename='', mode='wb', compresslevel=6, mtime=0) as out):
        out.write(MAGIC)
        cursor = 0
        for start, src, length in copies(old, new, old_zip, new_zip):
            if start < cursor:
                raise ValueError('Overlapping APK members')
            literal(out, new, cursor, start)
            out.write(struct.pack('>Bii', 254, src, length))
            cursor = start + length
        # Includes APK signing block, central directory and end-of-directory record.
        literal(out, new, cursor, len(new))
        out.write(b'\x00')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['base', 'target', 'patch']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    make_patch(args.base, args.target, args.patch)

#!/usr/bin/env python3
"""Extract a single file from a .pkg (xar) archive — no external deps.

Apple's newer InstallAssistant.pkg files (macOS 14+) embed the full installer
volume as a raw `SharedSupport.dmg` entry, which 7-Zip's xar reader fails on.
Offsets in the xar ToC are relative to the start of the heap
(header + compressed ToC); entry sizes are uncompressed sizes.

usage: xar_extract.py <pkg> <name> <out> [--verify]
       xar_extract.py <pkg> --sha1 <name>
"""
import gzip
import hashlib
import re
import struct
import sys
import zlib


def toc(xar_path):
    with open(xar_path, "rb") as f:
        head = f.read(28)
        hdr_size = struct.unpack(">H", head[4:6])[0]
        clen = struct.unpack(">Q", head[8:16])[0]
        f.seek(hdr_size)
        xml = zlib.decompress(f.read(clen)).decode()
        heap = hdr_size + clen
    entries = {}
    for m in re.finditer(r"<file id=\"\d+\">(.*?)</file>", xml, re.S):
        body = m.group(1)
        # the file's own <name> is the LAST one; earlier ones are inside <ea>
        names = re.findall(r"<name>([^<]+)</name>", body)
        data = re.search(r"<data>(.*?)</data>", body, re.S)
        if not names or not data:
            continue
        d = data.group(1)
        encoding = re.search(r'<encoding style="([^"]+)"', d)
        gz = bool(encoding and "gzip" in encoding.group(1))
        entries[names[-1]] = {
            "offset": int(re.search(r"<offset>(\d+)</offset>", d).group(1)),
            # <length> = bytes in archive, <size> = bytes when extracted
            "length": int(re.search(r"<length>(\d+)</length>", d).group(1)),
            "size": int(re.search(r"<size>(\d+)</size>", d).group(1)),
            "sha1": re.search(
                r'<extracted-checksum style="sha1">([0-9a-f]+)</extracted-checksum>', d
            ).group(1),
            "gzip": gz,
        }
    return entries, heap


def copy_entry(xar_path, heap, entry, out=None):
    """Stream an entry (gunzipping if needed) while hashing; returns sha1
    of the extracted bytes. `out` is an optional file object to write to."""
    h = hashlib.sha1()
    with open(xar_path, "rb") as f:
        f.seek(heap + entry["offset"])
        n = entry["length"]
        if entry["gzip"]:
            d = zlib.decompressobj()  # xar "gzip" blocks are zlib streams
            while n > 0:
                b = f.read(min(1 << 24, n))
                n -= len(b)
                e = d.decompress(b)
                h.update(e)
                if out:
                    out.write(e)
            e = d.flush()
            h.update(e)
            if out:
                out.write(e)
        else:
            while n > 0:
                b = f.read(min(1 << 24, n))
                n -= len(b)
                h.update(b)
                if out:
                    out.write(b)
    return h.hexdigest()


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.stderr.write(__doc__)
        sys.exit(1)
    xar_path, name = args[0], args[1]
    if name == "--sha1" and len(args) == 3:
        name = args[2]
        entries, heap = toc(xar_path)
        if name not in entries:
            sys.stderr.write("xar: no entry named %r (have: %s)\n" % (name, ", ".join(entries)))
            sys.exit(1)
        print(copy_entry(xar_path, heap, entries[name]))
        sys.exit(0)
    if name == "--list":
        entries, _ = toc(xar_path)
        for n in entries:
            print(n)
        sys.exit(0)
    entries, heap = toc(xar_path)
    if name not in entries:
        sys.stderr.write("xar: no entry named %r (have: %s)\n" % (name, ", ".join(entries)))
        sys.exit(1)
    entry = entries[name]
    if len(args) != 3:
        sys.stderr.write(__doc__)
        sys.exit(1)
    out_path = args[2]
    got = copy_entry(xar_path, heap, entry)
    if got != entry["sha1"]:
        sys.stderr.write("xar: %s FAILS sha1 (%s != %s) — archive corrupt\n" % (name, got, entry["sha1"]))
        sys.exit(2)
    with open(out_path, "wb") as out:
        copy_entry(xar_path, heap, entry, out)
    sys.stderr.write("xar: %s extracted, sha1 OK\n" % name)


if __name__ == "__main__":
    main()

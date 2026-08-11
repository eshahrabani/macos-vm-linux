#!/usr/bin/env python3
"""macrecovery client for Apple's osrecovery.apple.com service (stdlib only).

Fetches the bootable recovery image metadata for a board id (this is what
OSX-KVM's fetch-macOS-v2.py wraps — the Tahoe-era InstallAssistant.pkg no
longer contains anything bootable, so the recovery comes from here).

usage:
  recovery.py fetch <board-id> [os-type]     -> JSON: url, token, chunklist,
                                                product (image download + verify
                                                happen in bash/curl for resume)
  recovery.py verify <dmg> <chunklist>       -> verifies sha256 chunks, exit 0/1
"""
import hashlib
import json
import random
import struct
import sys
import urllib.request

HOST = "osrecovery.apple.com"
UA = "InternetRecovery/1.0"

ChunkListHeader = struct.Struct("<4sIBBBxQQQ")  # magic, hdr, ver, cm, sm, pad, count, coff, soff
Chunk = struct.Struct("<I32s")


def rand_id(n):
    return "".join(random.choice("0123456789abcdef") for _ in range(n))


def fetch_metadata(board_id, os_type="latest"):
    req = urllib.request.Request("http://%s/" % HOST, headers={"Host": HOST, "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        session = next(
            (c.split("=", 1)[1] for c in r.headers.get_all("Set-Cookie", []) if c.startswith("session=")),
            None,
        )
    if not session:
        raise RuntimeError("no session from osrecovery")

    post = "cid=%s\nsn=00000000000000000\nbid=%s\nk=%s\nfg=%s\nos=%s" % (
        rand_id(16), board_id, rand_id(64), rand_id(64), os_type
    )
    req = urllib.request.Request(
        "http://%s/InstallationPayload/RecoveryImage" % HOST,
        data=post.encode(),
        headers={"Host": HOST, "User-Agent": UA, "Cookie": "session=" + session,
                 "Content-Type": "text/plain"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode()
    info = {}
    for line in body.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            info[k] = v
    for key in ("AP", "AU", "AT", "CU", "CT"):
        if key not in info:
            raise RuntimeError("osrecovery response missing %s: %r" % (key, body[:200]))
    return {
        "product": info["AP"],
        "url": info["AU"],
        "token": info["AT"],
        "chunklist": info["CU"],
        "chunklist_token": info["CT"],
    }


def verify(dmg_path, cnk_path):
    with open(dmg_path, "rb") as dmgf, open(cnk_path, "rb") as cf:
        header = cf.read(ChunkListHeader.size)
        if len(header) != ChunkListHeader.size:
            return False, "chunklist too short"
        magic, hdr_size, file_ver, chunk_method, sig_method, count, coff, soff = ChunkListHeader.unpack(header)
        if magic != b"CNKL" or hdr_size != ChunkListHeader.size or count < 1:
            return False, "bad chunklist header"
        if coff != 0x24 or soff != 0x24 + Chunk.size * count:
            return False, "bad chunklist offsets"
        for i in range(count):
            chunk = cf.read(Chunk.size)
            if len(chunk) != Chunk.size:
                return False, "chunklist truncated"
            size, digest = Chunk.unpack(chunk)
            data = dmgf.read(size)
            if len(data) != size or hashlib.sha256(data).digest() != digest:
                return False, "chunk %d hash mismatch" % (i + 1)
        if dmgf.read(1) != b"":
            return False, "image larger than chunklist"
    return True, "ok"


def main():
    args = sys.argv[1:]
    if args and args[0] == "fetch" and len(args) in (2, 3):
        meta = fetch_metadata(args[1], args[2] if len(args) == 3 else "latest")
        print(json.dumps(meta))
    elif args and args[0] == "verify" and len(args) == 3:
        ok, msg = verify(args[1], args[2])
        sys.stderr.write(msg + "\n")
        sys.exit(0 if ok else 1)
    else:
        sys.stderr.write(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
